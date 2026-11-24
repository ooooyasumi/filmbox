// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"filmbox.local/cloudengine/providers"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testSecret = "a-long-random-test-secret-12345678"

func request(t *testing.T, s *server, method, path, body, secret string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	response := httptest.NewRecorder()
	s.handler().ServeHTTP(response, req)
	return response
}
func TestAuthenticationAndErrorScrubbing(t *testing.T) {
	s := newServer(testSecret)
	for _, path := range []string{"/health", "/v1/files/list", "/v1/files/resolve", "/v1/asset?account_id=x&file_id=x"} {
		if response := request(t, s, "GET", path, "", ""); response.Code != 401 {
			t.Fatal("unauthenticated endpoint", path, response.Code)
		}
	}
	if response := request(t, s, "GET", "/health", "", testSecret); response.Code != 200 {
		t.Fatal("health failed")
	}
	response := request(t, s, "POST", "/v1/accounts/connect", `{"account_id":"test","provider":"quark","credential":"private-secret"}`, testSecret)
	if response.Code != 422 || strings.Contains(response.Body.String(), "private-secret") {
		t.Fatal("credential echoed", response.Body.String())
	}
	response = request(t, s, "POST", "/v1/files/list", `{"account_id":"missing"}`, testSecret)
	if response.Code != 404 {
		t.Fatal("missing account", response.Code)
	}
	req := httptest.NewRequest("GET", "/health", nil)
	req.Header.Set("Authorization", "Bearer "+testSecret)
	req.Header.Set("Origin", "https://attacker.example")
	output := httptest.NewRecorder()
	s.handler().ServeHTTP(output, req)
	if output.Code != 403 {
		t.Fatal("cross-origin call accepted")
	}
}
func TestRealWebDAVConnectListResolveAndRange(t *testing.T) {
	media := []byte("0123456789abcdefghijklmnopqrstuvwxyz")
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, password, ok := r.BasicAuth()
		if !ok || user != "photos" || password != "cloud-password" {
			w.WriteHeader(401)
			return
		}
		if r.Method == "PROPFIND" {
			w.WriteHeader(207)
			io.WriteString(w, `<multistatus xmlns="DAV:"><response><href>/dav/test.mp4</href><propstat><prop><displayname>test.mp4</displayname><resourcetype/><getcontentlength>36</getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>`)
			return
		}
		http.ServeContent(w, r, "test.mp4", time.Time{}, bytes.NewReader(media))
	}))
	defer remote.Close()
	s := newServer(testSecret)
	local := httptest.NewServer(s.handler())
	defer local.Close()
	s.baseURL = local.URL
	response := request(t, s, "POST", "/v1/accounts/connect", `{"account_id":"test","provider":"webdav","endpoint":"`+remote.URL+`/dav","username":"photos","password":"cloud-password"}`, testSecret)
	if response.Code != 200 {
		t.Fatal("connect", response.Code, response.Body.String())
	}
	response = request(t, s, "POST", "/v1/files/list", `{"account_id":"test","folder_id":"/","path":"/"}`, testSecret)
	var listing struct {
		Entries []struct {
			ID string `json:"id"`
		} `json:"entries"`
	}
	json.Unmarshal(response.Body.Bytes(), &listing)
	if response.Code != 200 || len(listing.Entries) != 1 || listing.Entries[0].ID != "/test.mp4" {
		t.Fatal("listing", response.Body.String())
	}
	response = request(t, s, "POST", "/v1/files/resolve", `{"account_id":"test","file_id":"/test.mp4","path":"/test.mp4"}`, testSecret)
	var resolved struct {
		URL                string            `json:"url"`
		Headers            map[string]string `json:"headers"`
		ThumbnailAvailable bool              `json:"thumbnail_available"`
	}
	json.Unmarshal(response.Body.Bytes(), &resolved)
	if response.Code != 200 || !strings.HasPrefix(resolved.URL, local.URL+"/v1/asset?") || strings.Contains(response.Body.String(), "cloud-password") {
		t.Fatal("unsafe resolve", response.Body.String())
	}
	req, _ := http.NewRequest("GET", resolved.URL, nil)
	for k, v := range resolved.Headers {
		req.Header.Set(k, v)
	}
	req.Header.Set("Range", "bytes=5-9")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	chunk, _ := io.ReadAll(res.Body)
	if res.StatusCode != 206 || string(chunk) != "56789" || res.Header.Get("Content-Range") != "bytes 5-9/36" {
		t.Fatalf("range failed %d %q", res.StatusCode, chunk)
	}
	traffic := request(t, s, "GET", "/v1/traffic", "", testSecret)
	var usage struct {
		Received int64            `json:"received_bytes"`
		Session  string           `json:"session_id"`
		Days     map[string]int64 `json:"received_by_day"`
	}
	json.Unmarshal(traffic.Body.Bytes(), &usage)
	if usage.Received != 5 || usage.Session == "" || usage.Days[time.Now().Format("2006-01-02")] != 5 {
		t.Fatal("range traffic double-counted or missing", traffic.Body.String())
	}
	traffic = request(t, s, "GET", "/v1/traffic", "", testSecret)
	json.Unmarshal(traffic.Body.Bytes(), &usage)
	if usage.Received != 5 {
		t.Fatal("polling counted loopback bytes", usage.Received)
	}
	response = request(t, s, "POST", "/v1/accounts/disconnect", `{"account_id":"test"}`, testSecret)
	if response.Code != 200 {
		t.Fatal("disconnect")
	}
	response = request(t, s, "POST", "/v1/files/list", `{"account_id":"test"}`, testSecret)
	if response.Code != 404 {
		t.Fatal("account not forgotten")
	}
}

func TestMissingThumbnailNeverResolvesOriginal(t *testing.T) {
	s := newServer(testSecret)
	p := &renewingProvider{originalURL: "https://never-download.example"}
	s.accounts["test"] = &account{provider: p, links: make(map[string]cachedLink)}
	response := request(t, s, "POST", "/v1/files/resolve", `{"account_id":"test","file_id":"file","purpose":"thumbnail"}`, testSecret)
	var result map[string]string
	json.Unmarshal(response.Body.Bytes(), &result)
	if response.Code != 422 || result["code"] != "thumbnail_unavailable" || p.resolves != 0 {
		t.Fatal("missing thumbnail fell back to original", response.Body.String(), p.resolves)
	}
	response = request(t, s, "GET", "/v1/asset?account_id=test&file_id=file&purpose=thumbnail", "", testSecret)
	if response.Code != 422 || p.resolves != 0 {
		t.Fatal("asset bypassed thumbnail guard")
	}
	if result := request(t, s, "GET", "/v1/traffic", "", ""); result.Code != 401 {
		t.Fatal("traffic endpoint lacks authentication")
	}
}

type renewingProvider struct {
	originalURL string
	resolves    int
	fail        bool
}

func (p *renewingProvider) Name() string       { return "test" }
func (p *renewingProvider) Root() string       { return "/" }
func (p *renewingProvider) Credential() string { return "updated-session" }
func (p *renewingProvider) List(context.Context, string, string) ([]providers.Entry, error) {
	return nil, providers.ErrUnavailable
}
func (p *renewingProvider) Resolve(context.Context, string, string) (providers.Link, error) {
	p.resolves++
	if p.fail {
		return providers.Link{}, providers.ErrExpired
	}
	suffix := "/old"
	if p.resolves > 1 {
		suffix = "/new"
	}
	return providers.Link{URL: p.originalURL + suffix}, nil
}
func TestProxyRenewsExpiredLinksAndCredentialSurvivesError(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/old" {
			w.WriteHeader(403)
			return
		}
		io.WriteString(w, "fresh")
	}))
	defer upstream.Close()
	p := &renewingProvider{originalURL: upstream.URL}
	s := newServer(testSecret)
	s.accounts["test"] = &account{provider: p, links: make(map[string]cachedLink)}
	response := request(t, s, "GET", "/v1/asset?account_id=test&file_id=f", "", testSecret)
	if response.Code != 200 || response.Body.String() != "fresh" || p.resolves != 2 {
		t.Fatal("expired link was not refreshed", response.Code, p.resolves)
	}
	response = request(t, s, "POST", "/v1/files/list", `{"account_id":"test"}`, testSecret)
	var state map[string]string
	json.Unmarshal(response.Body.Bytes(), &state)
	if response.Code != 422 || state["credential"] != "updated-session" || state["code"] != "provider_unavailable" {
		t.Fatal("error lost updated credential")
	}
	response = request(t, s, "POST", "/v1/accounts/credential", `{"account_id":"test"}`, testSecret)
	json.Unmarshal(response.Body.Bytes(), &state)
	if response.Code != 200 || state["credential"] != "updated-session" {
		t.Fatal("credential snapshot failed")
	}
}
