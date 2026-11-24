// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"filmbox.local/cloudengine/providers"
)

type sessionProvider struct {
	url, cookie            string
	resolves, observations int
	listCookie             string
	observed               chan struct{}
}

func (p *sessionProvider) Name() string       { return "session-test" }
func (p *sessionProvider) Root() string       { return "/" }
func (p *sessionProvider) Credential() string { return p.cookie }
func (p *sessionProvider) List(context.Context, string, string) ([]providers.Entry, error) {
	if p.listCookie != "" {
		p.cookie = p.listCookie
	}
	return nil, providers.ErrUnavailable
}
func (p *sessionProvider) Resolve(context.Context, string, string) (providers.Link, error) {
	p.resolves++
	return providers.Link{URL: p.url, Headers: map[string]string{"Cookie": p.cookie}}, nil
}
func (p *sessionProvider) ObserveResponse(response *http.Response) {
	p.observations++
	for _, cookie := range response.Cookies() {
		if cookie.Name == "session" && cookie.Value != "" {
			p.cookie = "session=" + cookie.Value
		}
	}
	if p.observed != nil {
		select {
		case <-p.observed:
		default:
			close(p.observed)
		}
	}
}
func (p *sessionProvider) RefreshLinkCredentials(link providers.Link) providers.Link {
	link.Headers = map[string]string{"Cookie": p.cookie}
	return link
}

func sessionSnapshot(t *testing.T, response *httptest.ResponseRecorder) (string, uint64) {
	t.Helper()
	var snapshot struct {
		Credential string `json:"credential"`
		Revision   uint64 `json:"credential_revision"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Revision == 0 {
		t.Fatal("missing credential revision")
	}
	return snapshot.Credential, snapshot.Revision
}

func TestAccountCredentialRevisionIsAtomicAndStable(t *testing.T) {
	p := &sessionProvider{url: "https://download.example/photo", cookie: "session=old"}
	s := newServer(testSecret)
	s.accounts["test"] = &account{provider: p, links: make(map[string]cachedLink)}
	first := request(t, s, "POST", "/v1/accounts/credential", `{"account_id":"test"}`, testSecret)
	if cookie, revision := sessionSnapshot(t, first); cookie != "session=old" || revision != 1 {
		t.Fatal("initial session snapshot")
	}
	resolve := request(t, s, "POST", "/v1/files/resolve", `{"account_id":"test","file_id":"photo"}`, testSecret)
	if cookie, revision := sessionSnapshot(t, resolve); cookie != "session=old" || revision != 1 {
		t.Fatal("unchanged resolve increased revision")
	}
	p.listCookie = "session=new"
	failure := request(t, s, "POST", "/v1/files/list", `{"account_id":"test"}`, testSecret)
	if failure.Code != 422 {
		t.Fatal("fixture should fail listing")
	}
	if cookie, revision := sessionSnapshot(t, failure); cookie != "session=new" || revision != 2 {
		t.Fatal("error lost rotated session or revision")
	}
	latest := request(t, s, "POST", "/v1/accounts/credential", `{"account_id":"test"}`, testSecret)
	if cookie, revision := sessionSnapshot(t, latest); cookie != "session=new" || revision != 2 {
		t.Fatal("credential and revision were not one snapshot")
	}
	if cookie, revision := sessionSnapshot(t, first); cookie != "session=old" || revision != 1 {
		t.Fatal("encoded old snapshot changed")
	}
}

func TestProxyRotatedCookieIsReusedOnCachedLink(t *testing.T) {
	requests := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if requests == 1 {
			if r.Header.Get("Cookie") != "session=old" {
				t.Error("first request lost session")
			}
			http.SetCookie(w, &http.Cookie{Name: "session", Value: "new", Path: "/"})
		} else if r.Header.Get("Cookie") != "session=new" {
			t.Error("cached link sent stale session")
		}
		io.WriteString(w, "photo")
	}))
	defer upstream.Close()
	p := &sessionProvider{url: upstream.URL, cookie: "session=old"}
	s := newServer(testSecret)
	s.accounts["test"] = &account{provider: p, links: make(map[string]cachedLink)}
	request(t, s, "POST", "/v1/accounts/credential", `{"account_id":"test"}`, testSecret)
	for i := 0; i < 2; i++ {
		response := request(t, s, "GET", "/v1/asset?account_id=test&file_id=photo", "", testSecret)
		if response.Code != 200 || response.Body.String() != "photo" {
			t.Fatal("proxy failed")
		}
	}
	if p.resolves != 1 || p.observations != 2 {
		t.Fatal("cached links were not reused or response cookies were skipped")
	}
	latest := request(t, s, "POST", "/v1/accounts/credential", `{"account_id":"test"}`, testSecret)
	if cookie, revision := sessionSnapshot(t, latest); cookie != "session=new" || revision != 2 {
		t.Fatal("media response session was not retained")
	}
}

func TestProxyObservesRedirectCookieBeforeFinalBody(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			http.SetCookie(w, &http.Cookie{Name: "session", Value: "redirected", Path: "/"})
			http.Redirect(w, r, "/photo", 302)
			return
		}
		io.WriteString(w, "photo")
	}))
	defer upstream.Close()
	p := &sessionProvider{url: upstream.URL + "/redirect", cookie: "session=old"}
	s := newServer(testSecret)
	s.accounts["test"] = &account{provider: p, links: make(map[string]cachedLink)}
	response := request(t, s, "GET", "/v1/asset?account_id=test&file_id=photo", "", testSecret)
	if response.Code != 200 || p.observations != 2 || p.cookie != "session=redirected" {
		t.Fatal("redirect session cookie was discarded")
	}
}

func TestProxyErrorNeverWritesCredentialIntoMediaBody(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "session", Value: "renewed", Path: "/"})
		w.WriteHeader(403)
	}))
	defer upstream.Close()
	p := &sessionProvider{url: upstream.URL, cookie: "session=old"}
	s := newServer(testSecret)
	s.accounts["test"] = &account{provider: p, links: make(map[string]cachedLink)}
	response := request(t, s, "GET", "/v1/asset?account_id=test&file_id=photo", "", testSecret)
	if response.Code != 403 {
		t.Fatal("expected upstream refusal")
	}
	var result map[string]any
	json.Unmarshal(response.Body.Bytes(), &result)
	if result["code"] != "provider_unavailable" || response.Header().Get("X-Filmbox-Error") != "provider_unavailable" {
		t.Fatal("CDN refusal was misclassified as account expiration")
	}
	if result["credential"] != nil || result["credential_revision"] != nil || strings.Contains(response.Body.String(), "session=") || strings.Contains(response.Body.String(), "renewed") {
		t.Fatal("media error body leaked a credential into a potential cache staging file")
	}
	snapshot := request(t, s, "POST", "/v1/accounts/credential", `{"account_id":"test"}`, testSecret)
	if cookie, revision := sessionSnapshot(t, snapshot); cookie != "session=renewed" || revision != 1 {
		t.Fatal("control API lost the rotated credential after a failed transfer")
	}
	s.accounts["expired"] = &account{provider: &renewingProvider{fail: true}, links: make(map[string]cachedLink)}
	response = request(t, s, "GET", "/v1/asset?account_id=expired&file_id=photo", "", testSecret)
	result = make(map[string]any)
	json.Unmarshal(response.Body.Bytes(), &result)
	if response.Code != 422 || result["code"] != "authentication_expired" || result["credential"] != nil || result["credential_revision"] != nil || strings.Contains(response.Body.String(), "updated-session") {
		t.Fatal("provider authentication failure leaked a credential into media staging")
	}
}

func TestCanceledProxyKeepsCookieReceivedBeforeBody(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "session", Value: "rotated-before-body", Path: "/"})
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer upstream.Close()
	p := &sessionProvider{url: upstream.URL, cookie: "session=old", observed: make(chan struct{})}
	s := newServer(testSecret)
	s.accounts["test"] = &account{provider: p, links: make(map[string]cachedLink)}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/v1/asset?account_id=test&file_id=photo", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+testSecret)
	done := make(chan struct{})
	response := httptest.NewRecorder()
	go func() { s.handler().ServeHTTP(response, req); close(done) }()
	select {
	case <-p.observed:
	case <-time.After(2 * time.Second):
		t.Fatal("proxy did not observe headers before receiving the body")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("canceled transfer did not stop")
	}
	snapshot := request(t, s, "POST", "/v1/accounts/credential", `{"account_id":"test"}`, testSecret)
	if cookie, _ := sessionSnapshot(t, snapshot); cookie != "session=rotated-before-body" {
		t.Fatal("canceling the download discarded an accepted session renewal")
	}
	if strings.Contains(response.Body.String(), "credential") || strings.Contains(response.Body.String(), "rotated-before-body") {
		t.Fatal("canceled media request wrote a credential into its response body")
	}
}

type sessionRoundTripper func(*http.Request) (*http.Response, error)

func (t sessionRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return t(request)
}

func TestFailedInitialQuarkValidationKeepsRenewedCookieWithoutConnecting(t *testing.T) {
	previous := providers.Client
	providers.Client = &http.Client{Transport: sessionRoundTripper(func(req *http.Request) (*http.Response, error) {
		header := make(http.Header)
		header.Add("Set-Cookie", "__puus=renewed-during-validation; Path=/; Domain=.quark.cn")
		return &http.Response{StatusCode: 503, Header: header, Body: io.NopCloser(strings.NewReader(`{"status":503,"code":0}`)), Request: req}, nil
	})}
	defer func() { providers.Client = previous }()
	s := newServer(testSecret)
	response := request(t, s, "POST", "/v1/accounts/connect", `{"account_id":"test","provider":"quark","credential":"__puus=old"}`, testSecret)
	if response.Code != 422 {
		t.Fatal("temporary validation failure was accepted")
	}
	if cookie, revision := sessionSnapshot(t, response); cookie != "__puus=renewed-during-validation" || revision != 1 {
		t.Fatal("initial validation discarded the newly rotated session")
	}
	if s.accounts["test"] != nil {
		t.Fatal("failed validation installed an unverified connection")
	}
	for _, body := range []string{`{"account_id":"other","provider":"webdav","endpoint":"invalid"}`, `{"account_id":"other","provider":"baidu","credential":""}`} {
		if failure := request(t, s, "POST", "/v1/accounts/connect", body, testSecret); failure.Code != 422 {
			t.Fatal("invalid non-Quark constructor was accepted")
		}
	}
}

func TestReconnectRetainsMonotonicCredentialRevision(t *testing.T) {
	previous := providers.Client
	requests := 0
	providers.Client = &http.Client{Transport: sessionRoundTripper(func(req *http.Request) (*http.Response, error) {
		requests++
		header := make(http.Header)
		status, body := 200, `{"status":200,"code":0,"data":{"list":[]}}`
		switch requests {
		case 1:
			status, body = 503, `{"status":503,"code":0}`
			header.Add("Set-Cookie", "__puus=after-failed-validation; Path=/")
		case 2:
			header.Add("Set-Cookie", "__puus=after-successful-connect; Path=/")
		case 3:
			header.Add("Set-Cookie", "__puus=after-reconnect; Path=/")
		}
		return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
	})}
	defer func() { providers.Client = previous }()
	s := newServer(testSecret)
	connect := func(cookie string) *httptest.ResponseRecorder {
		body, _ := json.Marshal(connectionRequest{AccountID: "test", Provider: "quark", Credential: cookie})
		return request(t, s, "POST", "/v1/accounts/connect", string(body), testSecret)
	}
	failed := connect("__puus=initial")
	if failed.Code != 422 {
		t.Fatal("fixture expected failed initial validation")
	}
	if cookie, revision := sessionSnapshot(t, failed); cookie != "__puus=after-failed-validation" || revision != 1 {
		t.Fatal("first failed connect snapshot")
	}
	success := connect("__puus=after-failed-validation")
	if success.Code != 200 {
		t.Fatal("connect did not recover")
	}
	if cookie, revision := sessionSnapshot(t, success); cookie != "__puus=after-successful-connect" || revision != 2 {
		t.Fatal("successful connect reused the failed connection revision")
	}
	reconnect := connect("__puus=after-successful-connect")
	if reconnect.Code != 200 {
		t.Fatal("reconnect did not succeed")
	}
	if cookie, revision := sessionSnapshot(t, reconnect); cookie != "__puus=after-reconnect" || revision != 3 {
		t.Fatal("replacement connection reset the revision")
	}
	for _, path := range []string{"/v1/accounts/credential", "/v1/files/list"} {
		snapshot := request(t, s, "POST", path, `{"account_id":"test"}`, testSecret)
		if cookie, revision := sessionSnapshot(t, snapshot); cookie != "__puus=after-reconnect" || revision != 3 {
			t.Fatal("unchanged session did not retain its revision")
		}
	}
}

func TestSupersededAccountSnapshotCannotAdvanceCredentialRevision(t *testing.T) {
	state := &accountCredentialState{generation: 2, credential: "session=current", revision: 4}
	old := &account{provider: &sessionProvider{cookie: "session=late-old-cookie"}, credentialState: state, generation: 1}
	response := httptest.NewRecorder()
	old.mu.Lock()
	writeAccountError(response, 422, providers.ErrUnavailable, old)
	old.mu.Unlock()
	var payload map[string]any
	json.Unmarshal(response.Body.Bytes(), &payload)
	if response.Code != 409 || payload["code"] != "connection_superseded" || payload["credential"] != nil {
		t.Fatal("late connection snapshot was allowed to expose a new credential revision")
	}
	if state.revision != 4 || state.credential != "session=current" {
		t.Fatal("late old session changed the shared credential state")
	}
	current := &account{provider: &sessionProvider{cookie: "session=newest"}, credentialState: state, generation: 2}
	response = httptest.NewRecorder()
	current.mu.Lock()
	writeAccountJSON(response, 200, make(map[string]any), current)
	current.mu.Unlock()
	if cookie, revision := sessionSnapshot(t, response); cookie != "session=newest" || revision != 5 {
		t.Fatal("current generation could not advance its credential revision")
	}
}

func TestNewConnectionAndDisconnectSupersedePendingConnect(t *testing.T) {
	for _, disconnect := range []bool{false, true} {
		t.Run(map[bool]string{false: "new connection wins", true: "disconnect wins"}[disconnect], func(t *testing.T) {
			started, release := make(chan struct{}), make(chan struct{})
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasPrefix(r.URL.Path, "/slow/") {
					close(started)
					<-release
				}
				w.WriteHeader(207)
				io.WriteString(w, `<multistatus xmlns="DAV:"></multistatus>`)
			}))
			defer upstream.Close()
			s := newServer(testSecret)
			connectBody := func(path string) string {
				body, _ := json.Marshal(connectionRequest{AccountID: "test", Provider: "webdav", Endpoint: upstream.URL + path})
				return string(body)
			}
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() { done <- request(t, s, "POST", "/v1/accounts/connect", connectBody("/slow/"), testSecret) }()
			select {
			case <-started:
			case <-time.After(2 * time.Second):
				close(release)
				t.Fatal("pending connection never began")
			}
			if disconnect {
				response := request(t, s, "POST", "/v1/accounts/disconnect", `{"account_id":"test"}`, testSecret)
				if response.Code != 200 {
					t.Fatal("disconnect failed")
				}
			} else {
				fresh := request(t, s, "POST", "/v1/accounts/connect", connectBody("/fresh/"), testSecret)
				if fresh.Code != 200 {
					close(release)
					t.Fatal("fresh connection failed")
				}
				if cookie, revision := sessionSnapshot(t, fresh); cookie != "" || revision != 1 {
					t.Fatal("connect snapshot revision missing")
				}
			}
			close(release)
			select {
			case old := <-done:
				if old.Code != 409 {
					t.Fatal("old connection was not superseded")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("old connection did not finish")
			}
			s.mu.Lock()
			a := s.accounts["test"]
			s.mu.Unlock()
			if disconnect {
				if a != nil {
					t.Fatal("pending request resurrected disconnected account")
				}
				return
			}
			link, err := a.provider.Resolve(context.Background(), "/photo", "/photo")
			if err != nil || !strings.Contains(link.URL, "/fresh/photo") {
				t.Fatal("old connection overwrote new session")
			}
		})
	}
}
