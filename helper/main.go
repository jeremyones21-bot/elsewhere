// elsewhere-helper drives connected iPhones on behalf of the Elsewhere app.
//
// It speaks newline-delimited JSON: commands arrive on stdin, events leave on stdout.
// Everything that talks to a phone lives here so the Swift app never links go-ios.
//
//	-> {"id":1,"cmd":"set","udid":"…","lat":40.7,"lon":-74.0}
//	-> {"id":2,"cmd":"reset","udid":"…"}
//	<- {"type":"devices","devices":[{"udid":"…","name":"…","ios":"18.1","state":"ready"}]}
//	<- {"type":"result","id":1,"ok":true}
//
// iOS 17+ only exposes the developer services over a CoreDevice tunnel. We run that tunnel
// in-process with userspace networking, so nothing needs root.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/danielpaulus/go-ios/ios"
	"github.com/danielpaulus/go-ios/ios/amfi"
	"github.com/danielpaulus/go-ios/ios/imagemounter"
	"github.com/danielpaulus/go-ios/ios/instruments"
	"github.com/danielpaulus/go-ios/ios/tunnel"
)

// Device states, in the order a phone moves through them.
const (
	stateTrust     = "trust"     // waiting for "Trust This Computer"
	stateDevMode   = "devmode"   // Developer Mode is off
	stateTunnel    = "tunnel"    // building the CoreDevice tunnel
	statePreparing = "preparing" // fetching / mounting the developer disk image
	stateReady     = "ready"
	stateError     = "error"
)

type deviceInfo struct {
	UDID   string `json:"udid"`
	Name   string `json:"name"`
	IOS    string `json:"ios"`
	State  string `json:"state"`
	Detail string `json:"detail,omitempty"`
}

type command struct {
	ID   int     `json:"id"`
	Cmd  string  `json:"cmd"`
	UDID string  `json:"udid"`
	Lat  float64 `json:"lat"`
	Lon  float64 `json:"lon"`
}

// phone is everything we know about one attached device.
type phone struct {
	mu        sync.Mutex // serialises all traffic to this device
	entry     ios.DeviceEntry
	info      deviceInfo
	major     int
	rsd       *ios.DeviceEntry // tunnel-backed entry, once the tunnel is up
	imageOK   bool
	pairTried bool
	revealed  bool
	loc       *instruments.LocationSimulationService
}

type helper struct {
	supportDir string
	tm         *tunnel.TunnelManager

	mu     sync.Mutex
	phones map[string]*phone

	outMu sync.Mutex
	out   *json.Encoder
}

const tunnelInfoPort = 28150 // away from go-ios's default 28100 so a CLI agent can coexist

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn})))

	home, _ := os.UserHomeDir()
	support := filepath.Join(home, "Library", "Application Support", "Elsewhere")
	if len(os.Args) > 1 {
		support = os.Args[1]
	}
	pairDir := filepath.Join(support, "pairing")
	_ = os.MkdirAll(pairDir, 0o700)
	_ = os.MkdirAll(filepath.Join(support, "images"), 0o755)

	pm, err := tunnel.NewPairRecordManager(pairDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "pair record manager:", err)
		os.Exit(1)
	}

	h := &helper{
		supportDir: support,
		tm:         tunnel.NewTunnelManagerForDevice(pm, true, "", tunnelInfoPort),
		phones:     map[string]*phone{},
		out:        json.NewEncoder(os.Stdout),
	}

	ctx, cancel := context.WithCancel(context.Background())
	go h.tunnelLoop(ctx)
	go h.pollLoop(ctx)

	h.readCommands(os.Stdin)

	// stdin closed: the app quit. Leave the phone at its real location.
	cancel()
	h.mu.Lock()
	for _, p := range h.phones {
		p.mu.Lock()
		if p.loc != nil {
			_ = p.loc.StopSimulateLocation()
		}
		p.mu.Unlock()
	}
	h.mu.Unlock()
}

func (h *helper) emit(v any) {
	h.outMu.Lock()
	defer h.outMu.Unlock()
	_ = h.out.Encode(v)
}

func (h *helper) readCommands(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		var c command
		if err := json.Unmarshal(sc.Bytes(), &c); err != nil {
			continue
		}
		// Each command runs on its own goroutine; the per-phone mutex keeps them ordered
		// enough for one device, and a slow phone never blocks another.
		go h.handle(c)
	}
}

func (h *helper) handle(c command) {
	var err error
	switch c.Cmd {
	case "set":
		err = h.setLocation(c.UDID, c.Lat, c.Lon)
	case "reset":
		err = h.resetLocation(c.UDID)
	case "refresh":
		h.poll()
	default:
		err = fmt.Errorf("unknown command %q", c.Cmd)
	}
	res := map[string]any{"type": "result", "id": c.ID, "ok": err == nil}
	if err != nil {
		res["error"] = err.Error()
	}
	h.emit(res)
}

func (h *helper) tunnelLoop(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := h.tm.UpdateTunnels(ctx); err != nil {
				slog.Debug("update tunnels", "err", err)
			}
		}
	}
}

func (h *helper) pollLoop(ctx context.Context) {
	h.poll()
	t := time.NewTicker(1500 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			h.poll()
		}
	}
}

var lastSnapshot string

// poll reconciles attached devices with what we know and publishes the list when it changes.
func (h *helper) poll() {
	list, err := ios.ListDevices()
	if err != nil {
		h.emit(map[string]any{"type": "devices", "devices": []deviceInfo{}, "error": "usbmuxd unavailable: " + err.Error()})
		return
	}

	seen := map[string]bool{}
	for _, d := range list.DeviceList {
		// Only USB. A Wi-Fi entry for the same phone would show up as a duplicate.
		if d.Properties.ConnectionType != "" && d.Properties.ConnectionType != "USB" {
			continue
		}
		udid := d.Properties.SerialNumber
		seen[udid] = true
		h.mu.Lock()
		p, ok := h.phones[udid]
		if !ok {
			p = &phone{entry: d, info: deviceInfo{UDID: udid, Name: "iPhone", State: stateTrust}}
			h.phones[udid] = p
		}
		h.mu.Unlock()
		p.entry = d
		h.advance(p)
	}

	h.mu.Lock()
	for udid, p := range h.phones {
		if !seen[udid] {
			if p.loc != nil {
				p.loc.Close()
			}
			delete(h.phones, udid)
		}
	}
	devices := make([]deviceInfo, 0, len(h.phones))
	for _, p := range h.phones {
		devices = append(devices, p.info)
	}
	h.mu.Unlock()

	b, _ := json.Marshal(devices)
	if string(b) != lastSnapshot {
		lastSnapshot = string(b)
		h.emit(map[string]any{"type": "devices", "devices": devices})
	}
}

// advance walks one phone as far along the setup path as it will go right now.
// It never blocks long while holding the phone lock except for the one-time image download.
func (h *helper) advance(p *phone) {
	if !p.mu.TryLock() {
		return // a location command is in flight; check next tick
	}
	defer p.mu.Unlock()

	set := func(state, detail string) { p.info.State, p.info.Detail = state, detail }

	// 1. Trust. Without a pair record nothing else on the phone will talk to us.
	values, err := ios.GetValues(p.entry)
	if err != nil {
		if !p.pairTried {
			p.pairTried = true
			go func(e ios.DeviceEntry) { _ = ios.Pair(e) }(p.entry) // raises the Trust prompt
		}
		set(stateTrust, "Unlock your iPhone and tap Trust.")
		p.rsd, p.imageOK = nil, false
		return
	}
	p.info.Name = values.Value.DeviceName
	p.info.IOS = values.Value.ProductVersion
	p.major, _ = strconv.Atoi(strings.SplitN(values.Value.ProductVersion, ".", 2)[0])

	// 2. Developer Mode (iOS 16+).
	if p.major >= 16 {
		on, err := imagemounter.IsDevModeEnabled(p.entry)
		if err == nil && !on {
			if !p.revealed {
				p.revealed = true
				if c, err := amfi.New(p.entry); err == nil {
					_ = c.RevealDevMode() // makes the toggle visible in Settings
					c.Close()
				}
			}
			set(stateDevMode, "Turn on Developer Mode in Settings › Privacy & Security, then restart.")
			p.rsd, p.imageOK = nil, false
			return
		}
	}

	// 3. Tunnel (iOS 17+). Older phones use the plain usbmux services.
	target := p.entry
	if p.major >= 17 {
		if p.rsd == nil {
			t, err := h.tm.FindTunnel(p.info.UDID)
			if err != nil || t.Address == "" {
				set(stateTunnel, "Connecting…")
				return
			}
			dev, err := rsdDevice(p.entry, t)
			if err != nil {
				set(stateTunnel, "Connecting…")
				return
			}
			p.rsd = &dev
		}
		target = *p.rsd
	}

	// 4. Developer disk image. Downloaded once per iOS version, cached under images/.
	if !p.imageOK {
		mounted, err := imageMounted(target)
		if err != nil {
			p.rsd = nil // a stale tunnel is the usual cause; rebuild it
			set(stateTunnel, "Connecting…")
			return
		}
		if !mounted {
			set(statePreparing, "Downloading developer image…")
			h.emitSingle(p)
			path, err := imagemounter.DownloadImageFor(target, filepath.Join(h.supportDir, "images"))
			if err != nil {
				set(stateError, "Couldn't download the developer image: "+err.Error())
				return
			}
			set(statePreparing, "Mounting developer image…")
			h.emitSingle(p)
			if err := imagemounter.MountImage(target, path); err != nil {
				set(stateError, "Couldn't mount the developer image. Unlock the phone and try again.")
				return
			}
		}
		p.imageOK = true
	}

	set(stateReady, "")
}

// emitSingle pushes an in-progress state out before a slow step, so the UI isn't silent.
func (h *helper) emitSingle(p *phone) {
	h.mu.Lock()
	devices := make([]deviceInfo, 0, len(h.phones))
	for _, q := range h.phones {
		if q == p {
			devices = append(devices, p.info)
		} else {
			devices = append(devices, q.info)
		}
	}
	h.mu.Unlock()
	h.emit(map[string]any{"type": "devices", "devices": devices})
}

func rsdDevice(base ios.DeviceEntry, t tunnel.Tunnel) (ios.DeviceEntry, error) {
	base.UserspaceTUN = t.UserspaceTUN
	base.UserspaceTUNHost = ios.HttpApiHost()
	base.UserspaceTUNPort = t.UserspaceTUNPort
	svc, err := ios.NewWithAddrPortDevice(t.Address, t.RsdPort, base)
	if err != nil {
		return ios.DeviceEntry{}, err
	}
	defer svc.Close()
	provider, err := svc.Handshake()
	if err != nil {
		return ios.DeviceEntry{}, err
	}
	dev, err := ios.GetDeviceWithAddress(base.Properties.SerialNumber, t.Address, provider)
	if err != nil {
		return ios.DeviceEntry{}, err
	}
	dev.UserspaceTUN = base.UserspaceTUN
	dev.UserspaceTUNHost = base.UserspaceTUNHost
	dev.UserspaceTUNPort = base.UserspaceTUNPort
	return dev, nil
}

func imageMounted(dev ios.DeviceEntry) (bool, error) {
	m, err := imagemounter.NewImageMounter(dev)
	if err != nil {
		return false, err
	}
	defer m.Close()
	sigs, err := m.ListImages()
	if err != nil {
		return false, err
	}
	return len(sigs) > 0, nil
}

func (h *helper) ready(udid string) (*phone, error) {
	h.mu.Lock()
	p, ok := h.phones[udid]
	h.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("iPhone not connected")
	}
	return p, nil
}

func (h *helper) target(p *phone) ios.DeviceEntry {
	if p.rsd != nil {
		return *p.rsd
	}
	return p.entry
}

// setLocation keeps one LocationSimulation channel open per phone. iOS drops the simulated
// location when that channel closes, so a channel per update would make routes flicker.
func (h *helper) setLocation(udid string, lat, lon float64) error {
	p, err := h.ready(udid)
	if err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.info.State != stateReady {
		return fmt.Errorf("iPhone isn't ready yet")
	}

	for attempt := 0; attempt < 2; attempt++ {
		if p.loc == nil {
			svc, err := instruments.NewLocationSimulationService(h.target(p))
			if err != nil {
				p.rsd, p.imageOK = nil, false // force the setup path to re-check next poll
				return fmt.Errorf("couldn't reach location service: %w", err)
			}
			p.loc = svc
		}
		if err = p.loc.StartSimulateLocation(lat, lon); err == nil {
			return nil
		}
		p.loc.Close()
		p.loc = nil
	}
	return err
}

func (h *helper) resetLocation(udid string) error {
	p, err := h.ready(udid)
	if err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.loc != nil {
		err := p.loc.StopSimulateLocation() // also closes the channel
		p.loc = nil
		return err
	}
	// Nothing open from this session (e.g. app relaunched): open one just to stop.
	svc, err := instruments.NewLocationSimulationService(h.target(p))
	if err != nil {
		return err
	}
	return svc.StopSimulateLocation()
}
