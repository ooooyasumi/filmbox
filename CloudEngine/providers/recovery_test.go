package providers

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHTTPFailureEvidence(t *testing.T) {
	for status, code := range map[int]string{401: "authentication_expired", 403: "access_denied", 404: "not_found", 410: "not_found", 429: "rate_limited", 503: "provider_unavailable", 504: "network_timeout"} {
		remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
			io.WriteString(w, "private-cookie=do-not-expose")
		}))
		_, err := DoJSON(context.Background(), "GET", remote.URL, nil, nil, &struct{}{})
		remote.Close()
		if err == nil || SafeError(err).Code != code {
			t.Fatalf("%d: %v", status, err)
		}
	}
	if SafeError(context.DeadlineExceeded).Code != "network_timeout" {
		t.Fatal("deadline lost its cause")
	}
}

func TestWebDAVDeniedListingIsNotAnEmptySnapshot(t *testing.T) {
	for _, body := range []string{
		`<multistatus xmlns="DAV:"><response><href>/dav/</href><status>HTTP/1.1 403 Forbidden</status></response></multistatus>`,
		`<multistatus xmlns="DAV:"><response><href>/dav/</href><propstat><prop/><status>HTTP/1.1 403 Forbidden</status></propstat></response></multistatus>`,
	} {
		remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(207); io.WriteString(w, body) }))
		_, err := NewWebDAV(context.Background(), remote.URL+"/dav", "", "")
		remote.Close()
		if err == nil || SafeError(err).Code != "access_denied" {
			t.Fatalf("inaccessible directory would erase old index: %v", err)
		}
	}
}

func TestBaiduRefreshFailureRequiresAuthenticationEvidence(t *testing.T) {
	for _, tc := range []struct {
		body string
		want string
	}{
		{`{"error":"invalid_grant"}`, "authentication_expired"},
		{`{"error":"temporarily_unavailable"}`, "provider_unavailable"},
		{`{"error":"invalid_client"}`, "provider_unavailable"},
		{`{}`, "provider_unavailable"},
	} {
		remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, tc.body) }))
		b := &Baidu{onlineAPI: remote.URL, credential: BaiduCredential{RefreshToken: "secret"}}
		err := b.refresh(context.Background())
		remote.Close()
		if err == nil || SafeError(err).Code != tc.want {
			t.Fatalf("%s: %v", tc.body, err)
		}
	}
}
