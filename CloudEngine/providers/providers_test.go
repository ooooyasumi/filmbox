// SPDX-License-Identifier: AGPL-3.0-only
package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestQuarkPaginationAndRenewal(t *testing.T) {
	pages := 0
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Cookie"), "__pus=login") || r.URL.Query().Get("pr") != "ucpro" {
			t.Error("missing provider session")
		}
		if r.URL.Path == "/file/download" {
			io.WriteString(w, `{"status":200,"code":0,"data":[{"download_url":"https://files.example/original","thumbnail":"https://files.example/thumb"}]}`)
			return
		}
		pages++
		w.Header().Set("Set-Cookie", "__puus=renewed; Path=/")
		files := make([]map[string]any, 0)
		count := 100
		if r.URL.Query().Get("_page") == "2" {
			count = 1
		}
		for i := 0; i < count; i++ {
			files = append(files, map[string]any{"fid": fmt.Sprint(pages, "-", i), "file_name": "A &amp; B.jpg", "file": true, "size": 24, "l_updated_at": 1700000000000})
		}
		json.NewEncoder(w).Encode(map[string]any{"status": 200, "code": 0, "data": map[string]any{"list": files}, "metadata": map[string]any{"_total": 101}})
	}))
	defer mock.Close()
	q := &Quark{cookie: "__pus=login; __puus=old", api: mock.URL, thumbnails: make(map[string]string)}
	entries, err := q.List(context.Background(), "0", "/")
	if err != nil || len(entries) != 101 || pages != 2 {
		t.Fatalf("pagination: %d, %d, %v", len(entries), pages, err)
	}
	if entries[0].Name != "A & B.jpg" || entries[0].Modified != "2023-11-14T22:13:20Z" {
		t.Fatalf("bad normalization: %#v", entries[0])
	}
	if !strings.Contains(q.Credential(), "__puus=renewed") || strings.Contains(q.Credential(), "__puus=old") {
		t.Fatal("session renewal lost")
	}
	link, err := q.Resolve(context.Background(), "file", "/file")
	if err != nil || link.Headers["Cookie"] != q.Credential() {
		t.Fatal("link lost session", err)
	}
	thumb, available, err := q.Thumbnail(context.Background(), "file", "/file")
	if err != nil || !available || thumb.URL != "https://files.example/thumb" {
		t.Fatal("thumbnail", err)
	}
}
func TestQuarkEmptyDownloadAndExpiredSession(t *testing.T) {
	for _, body := range []string{`{"status":200,"code":0,"data":[]}`, `{"status":401,"code":31001,"message":"secret-cookie"}`} {
		mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, body) }))
		q := &Quark{cookie: "x=private-secret", api: mock.URL, thumbnails: make(map[string]string)}
		_, err := q.Resolve(context.Background(), "f", "")
		if err == nil || strings.Contains(err.Error(), "secret") {
			t.Fatal("empty or expired response accepted", err)
		}
		mock.Close()
	}
}
func TestBaiduRefreshRetryAndMetadata(t *testing.T) {
	refreshes := 0
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/renew" {
			refreshes++
			if r.URL.Query().Get("refresh_ui") != "old-refresh" {
				t.Error("refresh token missing")
			}
			io.WriteString(w, `{"access_token":"new-access","refresh_token":"new-refresh"}`)
			return
		}
		if r.URL.Query().Get("access_token") != "new-access" {
			io.WriteString(w, `{"errno":111}`)
			return
		}
		if r.URL.Path == "/xpan/file" {
			io.WriteString(w, `{"errno":0,"list":[{"fs_id":123,"server_filename":"photo.jpg","isdir":0,"size":2048,"server_mtime":1700000100,"local_mtime":1700000000}]}`)
			return
		}
		io.WriteString(w, `{"errno":0,"list":[{"thumbs":{"url3":"https://photos.example/thumb.jpg"}}]}`)
	}))
	defer mock.Close()
	b := &Baidu{api: mock.URL, onlineAPI: mock.URL + "/renew", credential: BaiduCredential{AccessToken: "expired-access", RefreshToken: "old-refresh"}}
	entries, err := b.List(context.Background(), "folder-id", "/photos")
	if err != nil || len(entries) != 1 || entries[0].ID != "123" || entries[0].Modified != "2023-11-14T22:13:20Z" || refreshes != 1 {
		t.Fatalf("refresh/list: %#v %v", entries, err)
	}
	if !strings.Contains(b.Credential(), "new-refresh") {
		t.Fatal("rotated refresh token lost")
	}
	link, ok, err := b.Thumbnail(context.Background(), "123", "")
	if err != nil || !ok || link.URL != "https://photos.example/thumb.jpg" {
		t.Fatal("thumbnail", err)
	}
}
func TestBaiduEmptyRefreshIsRejected(t *testing.T) {
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"access_token":"","text":"token=private-secret"}`)
	}))
	defer mock.Close()
	b := &Baidu{onlineAPI: mock.URL, credential: BaiduCredential{RefreshToken: "private-secret"}}
	err := b.refresh(context.Background())
	if err != ErrUnavailable || strings.Contains(err.Error(), "private-secret") {
		t.Fatal("unsafe refresh failure", err)
	}
}
func TestNoProviderCoverFallsBackToOriginal(t *testing.T) {
	for _, provider := range []string{"baidu", "quark"} {
		originalRequests := 0
		mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/file/download" {
				io.WriteString(w, `{"status":200,"code":0,"data":[{"download_url":"https://unused.example/original"}]}`)
				return
			}
			if r.URL.Query().Get("dlink") == "1" {
				originalRequests++
			}
			io.WriteString(w, `{"errno":0,"list":[{}]}`)
		}))
		var err error
		if provider == "baidu" {
			b := &Baidu{api: mock.URL, credential: BaiduCredential{AccessToken: "test"}}
			_, _, err = b.Thumbnail(context.Background(), "123", "")
		} else {
			q := &Quark{api: mock.URL, cookie: "x=test", thumbnails: make(map[string]string)}
			_, _, err = q.Thumbnail(context.Background(), "123", "")
		}
		mock.Close()
		if err != ErrThumbnailUnavailable || originalRequests != 0 {
			t.Fatal("provider returned an original as a cover", provider, err, originalRequests)
		}
	}
}
func TestWebDAVScopeAndEscaping(t *testing.T) {
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || u != "user" || p != "password" {
			t.Fatal("basic auth missing")
		}
		if r.Method != "PROPFIND" || r.Header.Get("Depth") != "1" {
			t.Error("not a directory request")
		}
		w.WriteHeader(207)
		io.WriteString(w, `<multistatus xmlns="DAV:"><response><href>/dav/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response><response><href>/dav/相片%20A.jpg</href><propstat><prop><displayname>相片 A.jpg</displayname><resourcetype/><getcontentlength>42</getcontentlength><getlastmodified>Tue, 14 Nov 2023 22:13:20 GMT</getlastmodified></prop><status>HTTP/1.1 200 OK</status></propstat></response><response><href>/outside.jpg</href><propstat><prop><resourcetype/></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>`)
	}))
	defer mock.Close()
	w, err := NewWebDAV(context.Background(), mock.URL+"/dav", "user", "password")
	if err != nil {
		t.Fatal(err)
	}
	entries, err := w.List(context.Background(), "/", "/")
	if err != nil || len(entries) != 1 || entries[0].ID != "/相片 A.jpg" || entries[0].Size != 42 {
		t.Fatalf("bad DAV listing %#v %v", entries, err)
	}
	link, _ := w.Resolve(context.Background(), "/相片 A.jpg", "")
	if !strings.HasSuffix(link.URL, "/%E7%9B%B8%E7%89%87%20A.jpg") {
		t.Fatal("bad asset escaping", link.URL)
	}
	link, _ = w.Resolve(context.Background(), "/../../secret", "")
	if !strings.HasSuffix(link.URL, "/dav/secret") {
		t.Fatal("escaped endpoint root", link.URL)
	}
}
