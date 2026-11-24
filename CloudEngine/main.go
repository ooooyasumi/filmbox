// SPDX-License-Identifier: AGPL-3.0-only
// Filmbox Cloud Engine, derived in part from OpenList. See UPSTREAM.md.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"filmbox.local/cloudengine/providers"
)

const version = "0.2.0"

type account struct {
	mu              sync.Mutex
	provider        providers.Provider
	links           map[string]cachedLink
	credentialState *accountCredentialState
	generation      uint64
}
type accountCredentialState struct {
	mu         sync.Mutex
	credential string
	revision   uint64
	generation uint64
}
type cachedLink struct {
	link      providers.Link
	thumbnail bool
	cached    time.Time
}
type server struct {
	secret, baseURL   string
	mu                sync.Mutex
	accounts          map[string]*account
	connectGeneration map[string]uint64
	credentialStates  map[string]*accountCredentialState
	assets            *http.Client
	trafficStats      *trafficStats
}
type connectionRequest struct {
	AccountID  string `json:"account_id"`
	Provider   string `json:"provider"`
	Credential string `json:"credential"`
	Endpoint   string `json:"endpoint"`
	Username   string `json:"username"`
	Password   string `json:"password"`
}
type fileRequest struct {
	AccountID string `json:"account_id"`
	FolderID  string `json:"folder_id"`
	FileID    string `json:"file_id"`
	Path      string `json:"path"`
	Purpose   string `json:"purpose"`
	Direct    bool   `json:"direct"`
}

func newServer(secret string) *server {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = 30 * time.Second
	transport.IdleConnTimeout = 60 * time.Second
	return &server{secret: secret, accounts: make(map[string]*account), connectGeneration: make(map[string]uint64), credentialStates: make(map[string]*accountCredentialState), assets: &http.Client{Transport: transport}, trafficStats: newTrafficStats()}
}
func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.health)
	mux.HandleFunc("/v1/accounts/connect", s.connect)
	mux.HandleFunc("/v1/accounts/disconnect", s.disconnect)
	mux.HandleFunc("/v1/accounts/credential", s.credential)
	mux.HandleFunc("/v1/files/list", s.list)
	mux.HandleFunc("/v1/files/resolve", s.resolve)
	mux.HandleFunc("/v1/asset", s.asset)
	mux.HandleFunc("/v1/traffic", s.traffic)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		expected := "Bearer " + s.secret
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte(expected)) != 1 {
			writeError(w, http.StatusUnauthorized, &providers.Error{Code: "unauthorized", Message: "云盘连接验证失败。"})
			return
		}
		// A local browser page must not be able to drive the helper cross-origin.
		if origin := r.Header.Get("Origin"); origin != "" && origin != s.baseURL {
			writeError(w, http.StatusForbidden, providers.ErrInvalid)
			return
		}
		mux.ServeHTTP(w, r)
	})
}
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func writeError(w http.ResponseWriter, status int, err error) {
	safe := providers.SafeError(err)
	w.Header().Set("X-Filmbox-Error", safe.Code)
	writeJSON(w, status, map[string]string{"error": safe.Message, "code": safe.Code})
}
func writeAccountError(w http.ResponseWriter, status int, err error, a *account) {
	safe := providers.SafeError(err)
	w.Header().Set("X-Filmbox-Error", safe.Code)
	writeAccountJSON(w, status, map[string]any{"error": safe.Message, "code": safe.Code}, a)
}

// Call with a.mu held: the cookie and its revision must describe one snapshot.
// Swift uses the revision to reject responses delivered out of request order.
func writeAccountJSON(w http.ResponseWriter, status int, value map[string]any, a *account) {
	if a.credentialState == nil {
		a.credentialState = &accountCredentialState{generation: a.generation}
	}
	state := a.credentialState
	state.mu.Lock()
	if state.generation != a.generation {
		state.mu.Unlock()
		writeError(w, 409, &providers.Error{Code: "connection_superseded", Message: "此连接请求已取消。"})
		return
	}
	credential := a.provider.Credential()
	if state.revision == 0 || state.credential != credential {
		state.revision++
		state.credential = credential
	}
	value["credential"] = credential
	value["credential_revision"] = state.revision
	state.mu.Unlock()
	writeJSON(w, status, value)
}
func decode(w http.ResponseWriter, r *http.Request, value any) bool {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, providers.ErrInvalid)
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	decoder := json.NewDecoder(r.Body)
	if decoder.Decode(value) != nil {
		writeError(w, http.StatusBadRequest, providers.ErrInvalid)
		return false
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		writeError(w, http.StatusBadRequest, providers.ErrInvalid)
		return false
	}
	return true
}
func validID(raw string) bool {
	return len(raw) > 0 && len(raw) <= 200 && !strings.ContainsAny(raw, "\r\n\x00")
}
func (s *server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, 405, providers.ErrInvalid)
		return
	}
	writeJSON(w, 200, map[string]string{"status": "ok", "version": version})
}
func (s *server) connect(w http.ResponseWriter, r *http.Request) {
	var request connectionRequest
	if !decode(w, r, &request) {
		return
	}
	if !validID(request.AccountID) {
		writeError(w, 400, providers.ErrInvalid)
		return
	}
	s.mu.Lock()
	s.connectGeneration[request.AccountID]++
	generation := s.connectGeneration[request.AccountID]
	state := s.credentialStates[request.AccountID]
	if state == nil {
		state = &accountCredentialState{}
		s.credentialStates[request.AccountID] = state
	}
	state.mu.Lock()
	state.generation = generation
	state.mu.Unlock()
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	var p providers.Provider
	var err error
	switch request.Provider {
	case "baidu":
		p, err = providers.NewBaidu(ctx, request.Credential)
	case "quark":
		var q *providers.Quark
		q, err = providers.NewQuark(ctx, request.Credential)
		if q != nil {
			p = q
		}
	case "webdav":
		p, err = providers.NewWebDAV(ctx, request.Endpoint, request.Username, request.Password)
	default:
		err = providers.ErrInvalid
	}
	if err != nil {
		s.mu.Lock()
		current := s.connectGeneration[request.AccountID] == generation
		s.mu.Unlock()
		if !current || ctx.Err() != nil {
			writeError(w, 409, &providers.Error{Code: "connection_superseded", Message: "此连接请求已取消。"})
		} else if request.Provider == "quark" && p != nil {
			// Keep any rotated cookie from a failed validation, but do not replace
			// the installed connection until validation succeeds.
			a := &account{provider: p, credentialState: state, generation: generation}
			a.mu.Lock()
			writeAccountError(w, 422, err, a)
			a.mu.Unlock()
		} else {
			writeError(w, 422, err)
		}
		return
	}
	s.mu.Lock()
	if s.connectGeneration[request.AccountID] != generation || ctx.Err() != nil {
		s.mu.Unlock()
		writeError(w, 409, &providers.Error{Code: "connection_superseded", Message: "此连接请求已取消。"})
		return
	}
	if len(s.accounts) >= 64 && s.accounts[request.AccountID] == nil {
		s.mu.Unlock()
		writeError(w, 422, &providers.Error{Code: "account_limit", Message: "已连接的网盘账号过多。"})
		return
	}
	a := &account{provider: p, links: make(map[string]cachedLink), credentialState: state, generation: generation}
	s.accounts[request.AccountID] = a
	s.mu.Unlock()
	a.mu.Lock()
	defer a.mu.Unlock()
	writeAccountJSON(w, 200, map[string]any{"name": p.Name(), "root_id": p.Root()}, a)
}
func (s *server) disconnect(w http.ResponseWriter, r *http.Request) {
	var request fileRequest
	if !decode(w, r, &request) {
		return
	}
	s.mu.Lock()
	s.connectGeneration[request.AccountID]++
	if state := s.credentialStates[request.AccountID]; state != nil {
		state.mu.Lock()
		state.generation = s.connectGeneration[request.AccountID]
		state.mu.Unlock()
	}
	delete(s.credentialStates, request.AccountID)
	delete(s.accounts, request.AccountID)
	s.mu.Unlock()
	writeJSON(w, 200, map[string]bool{"disconnected": true})
}
func (s *server) credential(w http.ResponseWriter, r *http.Request) {
	var request fileRequest
	if !decode(w, r, &request) {
		return
	}
	a := s.getAccount(w, request.AccountID)
	if a == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	writeAccountJSON(w, 200, make(map[string]any), a)
}
func (s *server) getAccount(w http.ResponseWriter, id string) *account {
	s.mu.Lock()
	a := s.accounts[id]
	s.mu.Unlock()
	if a == nil {
		writeError(w, 404, &providers.Error{Code: "account_not_connected", Message: "请重新连接此网盘账号。"})
	}
	return a
}
func (s *server) list(w http.ResponseWriter, r *http.Request) {
	var request fileRequest
	if !decode(w, r, &request) {
		return
	}
	a := s.getAccount(w, request.AccountID)
	if a == nil {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	a.mu.Lock()
	defer a.mu.Unlock()
	if request.FolderID == "" {
		request.FolderID = a.provider.Root()
	}
	if request.Path == "" {
		request.Path = "/"
	}
	entries, err := a.provider.List(ctx, request.FolderID, request.Path)
	if err != nil {
		writeAccountError(w, 422, err, a)
		return
	}
	writeAccountJSON(w, 200, map[string]any{"entries": entries, "folder_id": request.FolderID, "path": request.Path}, a)
}
func (a *account) freshLink(link providers.Link) providers.Link {
	if refresher, ok := a.provider.(interface {
		RefreshLinkCredentials(providers.Link) providers.Link
	}); ok {
		return refresher.RefreshLinkCredentials(link)
	}
	return link
}
func (a *account) getLink(ctx context.Context, request fileRequest) (providers.Link, bool, error) {
	key := request.Purpose + "\x00" + request.FileID + "\x00" + request.Path
	if cached, ok := a.links[key]; ok && time.Since(cached.cached) < 2*time.Minute && (cached.link.ExpiresAt.IsZero() || time.Until(cached.link.ExpiresAt) > time.Minute) {
		return a.freshLink(cached.link), cached.thumbnail, nil
	}
	var link providers.Link
	var thumb bool
	var err error
	if request.Purpose == "thumbnail" {
		if p, ok := a.provider.(interface {
			Thumbnail(context.Context, string, string) (providers.Link, bool, error)
		}); ok {
			link, thumb, err = p.Thumbnail(ctx, request.FileID, request.Path)
		} else {
			err = providers.ErrThumbnailUnavailable
		}
	} else {
		link, err = a.provider.Resolve(ctx, request.FileID, request.Path)
	}
	if err == nil {
		if request.Purpose == "thumbnail" && !thumb {
			return providers.Link{}, false, providers.ErrThumbnailUnavailable
		}
		if len(a.links) > 2048 {
			a.links = make(map[string]cachedLink)
		}
		a.links[key] = cachedLink{link, thumb, time.Now()}
	}
	return a.freshLink(link), thumb, err
}
func (s *server) resolve(w http.ResponseWriter, r *http.Request) {
	var request fileRequest
	if !decode(w, r, &request) {
		return
	}
	if request.FileID == "" {
		writeError(w, 400, providers.ErrInvalid)
		return
	}
	a := s.getAccount(w, request.AccountID)
	if a == nil {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	a.mu.Lock()
	defer a.mu.Unlock()
	link, thumb, err := a.getLink(ctx, request)
	if err != nil {
		writeAccountError(w, 422, err, a)
		return
	}
	result := map[string]any{"url": link.URL, "headers": link.Headers, "thumbnail_available": thumb}
	if !request.Direct {
		query := url.Values{"account_id": {request.AccountID}, "file_id": {request.FileID}, "path": {request.Path}, "purpose": {request.Purpose}}
		result["url"] = s.baseURL + "/v1/asset?" + query.Encode()
		result["headers"] = map[string]string{"Authorization": "Bearer " + s.secret}
	}
	if !link.ExpiresAt.IsZero() {
		result["expires_at"] = link.ExpiresAt.UTC().Format(time.RFC3339)
	}
	writeAccountJSON(w, 200, result, a)
}

type observingTransport struct {
	base    http.RoundTripper
	account *account
}

func (t observingTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := t.base.RoundTrip(request)
	if response != nil {
		if response.Request == nil {
			response.Request = request
		}
		// This runs before streaming the body, so a canceled download still saves
		// a rotated session. Wrapping Transport also catches redirect responses.
		t.account.mu.Lock()
		if observer, ok := t.account.provider.(interface{ ObserveResponse(*http.Response) }); ok {
			observer.ObserveResponse(response)
		}
		t.account.mu.Unlock()
	}
	return response, err
}

func (s *server) asset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		writeError(w, 405, providers.ErrInvalid)
		return
	}
	query := r.URL.Query()
	request := fileRequest{AccountID: query.Get("account_id"), FileID: query.Get("file_id"), Path: query.Get("path"), Purpose: query.Get("purpose")}
	a := s.getAccount(w, request.AccountID)
	if a == nil {
		return
	}
	if request.FileID == "" {
		writeError(w, 400, providers.ErrInvalid)
		return
	}
	// This route is downloaded directly into media staging files. Its response
	// body must never contain credentials, even on an upstream failure. Session
	// snapshots belong to the authenticated control JSON API instead.
	client := *s.assets
	transport := client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	client.Transport = observingTransport{base: transport, account: a}
	var response *http.Response
	for attempt := 0; attempt < 2; attempt++ {
		a.mu.Lock()
		if attempt > 0 {
			delete(a.links, request.Purpose+"\x00"+request.FileID+"\x00"+request.Path)
			if invalidator, ok := a.provider.(interface{ Invalidate(string, string) }); ok {
				invalidator.Invalidate(request.FileID, request.Purpose)
			}
		}
		link, _, err := a.getLink(r.Context(), request)
		a.mu.Unlock()
		if err != nil {
			writeError(w, 422, err)
			return
		}
		if !providers.ValidURL(link.URL) {
			writeError(w, 422, providers.ErrUnavailable)
			return
		}
		upstream, _ := http.NewRequestWithContext(r.Context(), r.Method, link.URL, nil)
		for k, v := range link.Headers {
			upstream.Header.Set(k, v)
		}
		for _, key := range []string{"Range", "If-Range", "If-None-Match", "If-Modified-Since"} {
			if value := r.Header.Get(key); value != "" {
				upstream.Header.Set(key, value)
			}
		}
		response, err = client.Do(upstream)
		if err != nil {
			writeError(w, 502, providers.TransportError(err))
			return
		}
		if attempt == 0 && (response.StatusCode == 401 || response.StatusCode == 403) {
			response.Body.Close()
			continue
		}
		break
	}
	defer response.Body.Close()
	if response.StatusCode >= 400 && response.StatusCode != http.StatusRequestedRangeNotSatisfiable {
		failure := error(providers.StatusError(response.StatusCode))
		if response.StatusCode == 401 || response.StatusCode == 403 {
			// The signed link was already refreshed once. Verify login through
			// the provider API before ever asking the user to sign in again.
			a.mu.Lock()
			_, check := a.provider.List(r.Context(), a.provider.Root(), "/")
			a.mu.Unlock()
			failure = providers.ErrDenied
			if check != nil {
				failure = check
			}
		}
		writeError(w, response.StatusCode, failure)
		return
	}
	for _, key := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"} {
		if value := response.Header.Get(key); value != "" {
			w.Header().Set(key, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	if r.Method != http.MethodHead {
		s.trafficStats.begin()
		defer s.trafficStats.end()
		_, _ = io.Copy(w, &trafficReader{Reader: response.Body, stats: s.trafficStats})
	}
}

func main() {
	port := flag.Int("port", 0, "loopback listening port (0 selects a free port)")
	watchParent := flag.Bool("watch-parent", true, "quit when the launching parent exits")
	flag.Parse()
	secret := os.Getenv("FILMBOX_CLOUD_SECRET")
	_ = os.Unsetenv("FILMBOX_CLOUD_SECRET")
	if len(secret) < 16 || *port < 0 || *port > 65535 {
		fmt.Fprintln(os.Stderr, "Cloud Engine configuration is invalid.")
		os.Exit(2)
	}
	listener, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(*port)))
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cloud Engine cannot open its local port.")
		os.Exit(2)
	}
	s := newServer(secret)
	actualPort := listener.Addr().(*net.TCPAddr).Port
	s.baseURL = "http://127.0.0.1:" + strconv.Itoa(actualPort)
	httpServer := &http.Server{Handler: s.handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	parent := os.Getppid()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				_ = httpServer.Shutdown(shutdown)
				cancel()
				return
			case <-ticker.C:
				if *watchParent && (parent == 1 || os.Getppid() != parent) {
					stop()
				}
			}
		}
	}()
	_ = json.NewEncoder(os.Stdout).Encode(map[string]int{"port": actualPort})
	if err := httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
		fmt.Fprintln(os.Stderr, "Cloud Engine stopped unexpectedly.")
		os.Exit(1)
	}
}
