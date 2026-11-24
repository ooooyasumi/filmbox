// SPDX-License-Identifier: AGPL-3.0-only
package providers

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func quarkCookieResponse(t *testing.T, raw, sent string, cookies ...*http.Cookie) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, raw, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Cookie", sent)
	response := &http.Response{Request: req, Header: make(http.Header)}
	for _, cookie := range cookies {
		response.Header.Add("Set-Cookie", cookie.String())
	}
	return response
}

func TestQuarkCookieRotationPreservesSessionAndIgnoresStaleResponses(t *testing.T) {
	q := &Quark{api: "https://drive.quark.cn/1/clouddrive", cookie: "__puus=old; __pus=login; device=stable"}
	initial := q.Credential()
	q.ObserveResponse(quarkCookieResponse(t, q.api+"/file/sort", initial,
		&http.Cookie{Name: "__puus", Value: "new", Domain: ".quark.cn", Path: "/"},
		&http.Cookie{Name: "__kps", Value: "session", Domain: ".quark.cn", Path: "/"},
		&http.Cookie{Name: "__pus", MaxAge: -1, Domain: ".quark.cn", Path: "/"},
		&http.Cookie{Name: "expired", Value: "discard", Expires: time.Now().Add(-time.Hour)},
		&http.Cookie{Name: "foreign", Value: "discard", Domain: "unrelated.example"},
		&http.Cookie{Name: "specific", Value: "discard", Path: "/account"}))
	accepted := q.Credential()
	for _, wanted := range []string{"__puus=new", "__pus=login", "__kps=session", "device=stable"} {
		if !strings.Contains(accepted, wanted) {
			t.Fatal("valid session cookie was lost")
		}
	}
	for _, unwanted := range []string{"discard", "__puus=old"} {
		if strings.Contains(accepted, unwanted) {
			t.Fatal("invalid response cookie was accepted")
		}
	}
	q.ObserveResponse(quarkCookieResponse(t, "https://download.quark.cn/photo", initial,
		&http.Cookie{Name: "__puus", Value: "late-old", Domain: ".quark.cn"},
		&http.Cookie{Name: "extra", Value: "safe", Domain: ".quark.cn"}))
	if !strings.Contains(q.Credential(), "__puus=new") || !strings.Contains(q.Credential(), "extra=safe") {
		t.Fatal("old media response overwrote the current session")
	}
	q.ObserveResponse(quarkCookieResponse(t, "https://unrelated.example/photo", q.Credential(), &http.Cookie{Name: "__puus", Value: "foreign"}))
	if strings.Contains(q.Credential(), "foreign") {
		t.Fatal("foreign media response changed the session")
	}
	q.ObserveResponse(quarkCookieResponse(t, q.api+"/file/sort", q.Credential(),
		&http.Cookie{Name: "__puus", Value: "first"}, &http.Cookie{Name: "__puus", Value: "last"}))
	if !strings.Contains(q.Credential(), "__puus=last") {
		t.Fatal("last cookie in one response did not win")
	}
	accepted = q.Credential()
	q.ObserveResponse(quarkCookieResponse(t, "https://download.quark.cn/photo", accepted,
		&http.Cookie{Name: "__puus", Value: "cdn-host-only"},
		&http.Cookie{Name: "__kps", Value: "public-suffix", Domain: ".cn"}))
	if q.Credential() != accepted {
		t.Fatal("CDN-only or public-suffix cookie overwrote a Drive session")
	}
	q.ObserveResponse(quarkCookieResponse(t, q.api+"/file/sort", accepted,
		&http.Cookie{Name: "__puus", Value: "api-scope", Path: "/1/clouddrive/"}))
	if !strings.Contains(q.Credential(), "__puus=api-scope") {
		t.Fatal("valid API cookie with a trailing-slash root path was discarded")
	}
}

func TestQuarkAuthenticationClassification(t *testing.T) {
	cases := []struct {
		name string
		http int
		body string
		want string
	}{
		{"http unauthorized", 401, `not-json`, "authentication_expired"},
		{"json unauthorized", 200, `{"status":401,"code":0}`, "authentication_expired"},
		{"explicit session code", 200, `{"status":200,"code":31001}`, "authentication_expired"},
		{"explicit relogin code", 200, `{"status":200,"code":31004}`, "authentication_expired"},
		{"forbidden is not logout", 403, `{"status":403,"code":0}`, "access_denied"},
		{"forbidden auth code", 403, `{"status":403,"code":31001}`, "authentication_expired"},
		{"capacity is not logout", 200, `{"status":400,"code":32003}`, "provider_error"},
		{"file error is not logout", 200, `{"status":400,"code":41017}`, "provider_error"},
		{"throttled is not logout", 429, `{"status":429,"code":0}`, "rate_limited"},
		{"missing data is not logout", 200, `{"status":200,"code":0}`, "provider_unavailable"},
		{"malformed is not logout", 200, `not-json`, "provider_unavailable"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var requests atomic.Int32
			mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				w.WriteHeader(tc.http)
				io.WriteString(w, tc.body)
			}))
			defer mock.Close()
			q := &Quark{api: mock.URL, cookie: "__puus=unchanged"}
			_, err := q.List(context.Background(), "0", "/")
			if err == nil || SafeError(err).Code != tc.want || requests.Load() != 1 {
				t.Fatal("incorrect authentication classification", SafeError(err).Code, requests.Load())
			}
			if q.Credential() != "__puus=unchanged" {
				t.Fatal("ordinary failure changed the credential")
			}
		})
	}
}

func TestQuarkRetriesOnlyAfterRotationAndReplaysBodyOnce(t *testing.T) {
	for _, succeeds := range []bool{true, false} {
		t.Run(map[bool]string{true: "rotated cookie recovers", false: "retry is bounded"}[succeeds], func(t *testing.T) {
			var requests atomic.Int32
			mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				request := requests.Add(1)
				body, _ := io.ReadAll(r.Body)
				if string(body) != `{"fids":["photo"]}` {
					t.Error("request body was not replayed")
				}
				if request == 1 {
					http.SetCookie(w, &http.Cookie{Name: "__puus", Value: "renewed", Path: "/"})
					io.WriteString(w, `{"status":401,"code":31001}`)
					return
				}
				if !strings.Contains(r.Header.Get("Cookie"), "__puus=renewed") {
					t.Error("retry sent stale cookie")
				}
				if !succeeds {
					http.SetCookie(w, &http.Cookie{Name: "__puus", Value: "again", Path: "/"})
					io.WriteString(w, `{"status":401,"code":31001}`)
					return
				}
				io.WriteString(w, `{"status":200,"code":0,"data":[{"download_url":"https://download.quark.cn/photo"}]}`)
			}))
			defer mock.Close()
			q := &Quark{api: mock.URL, cookie: "__puus=old"}
			_, err := q.Resolve(context.Background(), "photo", "")
			if requests.Load() != 2 || succeeds && err != nil || !succeeds && err != ErrExpired {
				t.Fatal("rotation retry failed or exceeded bound", requests.Load(), err)
			}
		})
	}
}

func TestQuarkCachedLinkUsesLatestCookieWithoutMutatingSharedHeaders(t *testing.T) {
	q := &Quark{api: "https://drive.quark.cn/1/clouddrive", cookie: "__puus=new"}
	original := Link{URL: "https://download.quark.cn/photo", Headers: map[string]string{"Cookie": "__puus=old", "Referer": "https://pan.quark.cn"}, ExpiresAt: time.Now().Add(time.Minute)}
	fresh := q.RefreshLinkCredentials(original)
	if fresh.Headers["Cookie"] != "__puus=new" || original.Headers["Cookie"] != "__puus=old" || fresh.URL != original.URL || fresh.ExpiresAt != original.ExpiresAt {
		t.Fatal("cached signed link did not keep its URL and refresh its cookie safely")
	}
}

func TestQuarkConcurrentSessionAndThumbnailAccess(t *testing.T) {
	q := &Quark{api: "https://drive.quark.cn/1/clouddrive", cookie: "__puus=initial", thumbnails: make(map[string]string)}
	var wait sync.WaitGroup
	for i := 0; i < 24; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for j := 0; j < 30; j++ {
				sent := q.Credential()
				q.ObserveResponse(quarkCookieResponse(t, q.api+"/file/sort", sent, &http.Cookie{Name: "__puus", Value: "rotated"}))
				q.setThumbnail("photo", "https://download.quark.cn/cover")
				q.thumbnail("photo")
				q.Invalidate("photo", "thumbnail")
				q.RefreshLinkCredentials(Link{Headers: map[string]string{"Cookie": "stale"}})
			}
		}()
	}
	wait.Wait()
	if _, err := url.Parse(q.Credential()); err != nil || q.Credential() == "" {
		t.Fatal("session was lost")
	}
}
