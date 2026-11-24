// SPDX-License-Identifier: AGPL-3.0-only
// Derived from OpenList drivers/quark_uc/{util,types,meta}.go,
// commit e72822f5390f4272c9fe9da8cabba3c1a270182f, copyright OpenList contributors.
// Filmbox: retain directory/download/session renewal logic only; use stdlib HTTP,
// validate authenticated directory access, bound pagination, handle empty results.
package providers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const quarkUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"

type Quark struct {
	mu                sync.RWMutex
	requestMu         sync.Mutex
	cookie, api, name string
	thumbnails        map[string]string
}

func NewQuark(ctx context.Context, credential string) (*Quark, error) {
	credential = strings.TrimSpace(credential)
	if credential == "" || !strings.Contains(credential, "=") || strings.ContainsAny(credential, "\r\n") {
		return nil, ErrInvalid
	}
	q := &Quark{cookie: credential, api: "https://drive.quark.cn/1/clouddrive", name: "夸克网盘", thumbnails: make(map[string]string)}
	// /config can succeed for guests. Checking a directory is required before
	// treating the isolated login's Cookie as an authenticated drive session.
	var response struct {
		Data *struct {
			List []quarkFile `json:"list"`
		} `json:"data"`
	}
	if err := q.request(ctx, "/file/sort", http.MethodGet, url.Values{"pdir_fid": {"0"}, "_size": {"1"}, "_page": {"1"}}, nil, &response); err != nil {
		// The response may have renewed a cookie even though validation failed.
		// Return the partial session to its Keychain owner without accepting it.
		return q, err
	}
	if response.Data == nil {
		return q, ErrUnavailable
	}
	return q, nil
}
func (q *Quark) Name() string { return q.name }
func (q *Quark) Root() string { return "0" }
func (q *Quark) Credential() string {
	q.mu.RLock()
	defer q.mu.RUnlock()
	return q.cookie
}
func (q *Quark) Invalidate(fileID, purpose string) {
	if purpose == "thumbnail" {
		q.mu.Lock()
		defer q.mu.Unlock()
		delete(q.thumbnails, fileID)
	}
}
func (q *Quark) request(ctx context.Context, endpoint, method string, params url.Values, body any, result any) error {
	// Quark rotates its session cookies in ordinary API responses. Serialize the
	// small API requests so the next request starts with the last accepted cookie.
	q.requestMu.Lock()
	defer q.requestMu.Unlock()
	if params == nil {
		params = make(url.Values)
	}
	params.Set("pr", "ucpro")
	params.Set("fr", "pc")
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			return ErrInvalid
		}
	}
	for attempt := 0; attempt < 2; attempt++ {
		sentCookie := q.Credential()
		err := q.requestOnce(ctx, q.api+endpoint+"?"+params.Encode(), method, data, sentCookie, result)
		// A server can rotate a cookie while rejecting the old one. Retry only
		// after an actual credential change, once; never loop or retry throttling.
		if err != ErrExpired || attempt != 0 || ctx.Err() != nil || sentCookie == q.Credential() {
			return err
		}
	}
	return ErrExpired
}

func (q *Quark) requestOnce(ctx context.Context, raw, method string, data []byte, credential string, result any) error {
	if !ValidURL(raw) {
		return ErrInvalid
	}
	req, err := http.NewRequestWithContext(ctx, method, raw, bytes.NewReader(data))
	if err != nil {
		return ErrInvalid
	}
	req.Header.Set("Cookie", credential)
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Referer", "https://pan.quark.cn")
	req.Header.Set("User-Agent", quarkUA)
	if len(data) > 0 {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := Client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return TransportError(err)
	}
	defer res.Body.Close()
	q.ObserveResponse(res)
	var rawBody json.RawMessage
	decodeErr := json.NewDecoder(io.LimitReader(res.Body, 24<<20)).Decode(&rawBody)
	if res.StatusCode == http.StatusUnauthorized {
		return ErrExpired
	}
	if res.StatusCode == http.StatusTooManyRequests {
		return ErrThrottled
	}
	if res.StatusCode >= 500 {
		return StatusError(res.StatusCode)
	}
	if decodeErr != nil {
		return ErrUnavailable
	}
	var status struct {
		Status int `json:"status"`
		Code   int `json:"code"`
	}
	if json.Unmarshal(rawBody, &status) != nil {
		return ErrUnavailable
	}
	// A generic 403 can be a signed-link, permission, or risk-control failure.
	// 32003 is a capacity error, not a login error. Only explicit authentication
	// signals are allowed to invalidate the account.
	if status.Status == http.StatusUnauthorized || status.Code == 31001 || status.Code == 31004 {
		return ErrExpired
	}
	if res.StatusCode == http.StatusTooManyRequests || status.Status == http.StatusTooManyRequests {
		return ErrThrottled
	}
	if res.StatusCode == http.StatusForbidden || status.Status == http.StatusForbidden {
		return ErrDenied
	}
	if status.Status >= 400 || status.Code != 0 || res.StatusCode < 200 || res.StatusCode >= 300 {
		return &Error{"provider_error", fmt.Sprintf("夸克网盘暂时无法完成请求（%d）。", status.Code)}
	}
	if result != nil && json.Unmarshal(rawBody, result) != nil {
		return ErrUnavailable
	}
	return nil
}

// ObserveResponse receives API and proxied media responses, including redirects.
// Accept only cookies from Quark's own origins. A late response made with an old
// cookie must not overwrite a newer cookie accepted by another in-flight request.
func (q *Quark) ObserveResponse(res *http.Response) {
	if res == nil || res.Request == nil || res.Request.URL == nil {
		return
	}
	host := strings.ToLower(res.Request.URL.Hostname())
	apiURL, _ := url.Parse(q.api)
	if host == "" || !(apiURL != nil && strings.EqualFold(host, apiURL.Hostname()) || res.Request.URL.Scheme == "https" && (host == "quark.cn" || strings.HasSuffix(host, ".quark.cn"))) {
		return
	}
	sent := (&http.Request{Header: http.Header{"Cookie": {res.Request.Header.Get("Cookie")}}}).Cookies()
	sentValues := make(map[string]string, len(sent))
	for _, cookie := range sent {
		sentValues[cookie.Name] = cookie.Value
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	current := (&http.Request{Header: http.Header{"Cookie": {q.cookie}}}).Cookies()
	currentValues := make(map[string]string, len(current))
	for _, cookie := range current {
		currentValues[cookie.Name] = cookie.Value
	}
	for _, cookie := range res.Cookies() {
		domain := strings.ToLower(strings.TrimPrefix(cookie.Domain, "."))
		if cookie.Name == "" || cookie.Value == "" || cookie.MaxAge < 0 || (!cookie.Expires.IsZero() && cookie.Expires.Before(time.Now())) {
			continue
		}
		if domain != "" && host != domain && !strings.HasSuffix(host, "."+domain) {
			continue
		}
		effectiveDomain := domain
		if effectiveDomain == "" {
			effectiveDomain = host
		}
		// A CDN's host-only cookie belongs to that CDN, not to the Drive API.
		// Domain=.quark.cn cookies can be shared; arbitrary public suffixes cannot.
		if apiURL == nil || !(strings.EqualFold(effectiveDomain, apiURL.Hostname()) || effectiveDomain == "quark.cn" && strings.HasSuffix(strings.ToLower(apiURL.Hostname()), ".quark.cn")) {
			continue
		}
		apiPath := strings.TrimSuffix(apiURL.Path, "/") + "/"
		if cookie.Path != "" && cookie.Path != "/" && apiPath != cookie.Path && !strings.HasPrefix(apiPath, strings.TrimSuffix(cookie.Path, "/")+"/") {
			continue
		}
		if currentValues[cookie.Name] != sentValues[cookie.Name] && currentValues[cookie.Name] != cookie.Value {
			continue
		}
		q.cookie = updateCookie(q.cookie, cookie.Name, cookie.Value)
	}
}

// Cached signed URLs remain useful after session rotation, but their captured
// Cookie header does not. Return a copy so concurrent downloads share no map.
func (q *Quark) RefreshLinkCredentials(link Link) Link {
	if _, ok := link.Headers["Cookie"]; !ok {
		return link
	}
	headers := make(map[string]string, len(link.Headers))
	for key, value := range link.Headers {
		headers[key] = value
	}
	headers["Cookie"] = q.Credential()
	link.Headers = headers
	return link
}

func (q *Quark) thumbnail(fileID string) string {
	q.mu.RLock()
	defer q.mu.RUnlock()
	return q.thumbnails[fileID]
}
func (q *Quark) setThumbnail(fileID, raw string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.thumbnails == nil {
		q.thumbnails = make(map[string]string)
	}
	q.thumbnails[fileID] = raw
}
func updateCookie(raw, name, value string) string {
	parts := strings.Split(raw, ";")
	result := make([]string, 0, len(parts)+1)
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" && !strings.HasPrefix(part, name+"=") {
			result = append(result, part)
		}
	}
	return strings.Join(append(result, name+"="+value), "; ")
}

type quarkFile struct {
	ID            string  `json:"fid"`
	Name          string  `json:"file_name"`
	Size          int64   `json:"size"`
	File          bool    `json:"file"`
	Created       int64   `json:"created_at"`
	Modified      int64   `json:"updated_at"`
	LocalCreated  int64   `json:"l_created_at"`
	LocalModified int64   `json:"l_updated_at"`
	Width         int     `json:"width"`
	Height        int     `json:"height"`
	Duration      float64 `json:"duration"`
	Thumbnail     string  `json:"thumbnail"`
}

func (q *Quark) List(ctx context.Context, folderID, _ string) ([]Entry, error) {
	if folderID == "" {
		folderID = "0"
	}
	params := url.Values{"pdir_fid": {folderID}, "_size": {"100"}, "_fetch_total": {"1"}, "fetch_all_file": {"1"}, "fetch_risk_file_name": {"1"}}
	entries := make([]Entry, 0)
	for page := 1; page <= 10000; page++ {
		params.Set("_page", strconv.Itoa(page))
		var response struct {
			Data *struct {
				List []quarkFile `json:"list"`
			} `json:"data"`
			Metadata struct {
				Total int `json:"_total"`
			} `json:"metadata"`
		}
		if err := q.request(ctx, "/file/sort", http.MethodGet, params, nil, &response); err != nil {
			return nil, err
		}
		if response.Data == nil {
			return nil, ErrUnavailable
		}
		for _, f := range response.Data.List {
			if f.ID == "" {
				continue
			}
			mtime, ctime := f.Modified, f.Created
			if f.LocalModified > 0 {
				mtime = f.LocalModified
			}
			if f.LocalCreated > 0 {
				ctime = f.LocalCreated
			}
			if ValidURL(f.Thumbnail) {
				q.setThumbnail(f.ID, f.Thumbnail)
			}
			entries = append(entries, Entry{ID: f.ID, Name: html.UnescapeString(f.Name), Size: f.Size, IsDirectory: !f.File, Modified: TimeMillis(mtime), Created: TimeMillis(ctime), Width: f.Width, Height: f.Height, Duration: f.Duration, Thumbnail: f.Thumbnail})
		}
		if len(response.Data.List) < 100 || (response.Metadata.Total > 0 && page*100 >= response.Metadata.Total) {
			return entries, nil
		}
	}
	return nil, &Error{"folder_too_large", "此文件夹项目过多，请选择更具体的子文件夹。"}
}
func (q *Quark) Resolve(ctx context.Context, fileID, _ string) (Link, error) {
	if fileID == "" {
		return Link{}, ErrInvalid
	}
	var response struct {
		Data []struct {
			URL       string `json:"download_url"`
			Thumbnail string `json:"thumbnail"`
		} `json:"data"`
	}
	if err := q.request(ctx, "/file/download", http.MethodPost, nil, map[string]any{"fids": []string{fileID}}, &response); err != nil {
		return Link{}, err
	}
	if len(response.Data) == 0 || !ValidURL(response.Data[0].URL) {
		return Link{}, ErrNotFound
	}
	if ValidURL(response.Data[0].Thumbnail) {
		q.setThumbnail(fileID, response.Data[0].Thumbnail)
	}
	return Link{URL: response.Data[0].URL, Headers: map[string]string{"Cookie": q.Credential(), "Referer": "https://pan.quark.cn", "User-Agent": quarkUA}, ExpiresAt: time.Now().Add(20 * time.Minute)}, nil
}
func (q *Quark) Thumbnail(ctx context.Context, fileID, filePath string) (Link, bool, error) {
	if raw := q.thumbnail(fileID); ValidURL(raw) {
		return Link{URL: raw, Headers: map[string]string{"Cookie": q.Credential(), "Referer": "https://pan.quark.cn", "User-Agent": quarkUA}, ExpiresAt: time.Now().Add(10 * time.Minute)}, true, nil
	}
	link, err := q.Resolve(ctx, fileID, filePath)
	if raw := q.thumbnail(fileID); err == nil && ValidURL(raw) {
		link.URL = raw
		return link, true, nil
	}
	if err != nil {
		return Link{}, false, err
	}
	return Link{}, false, ErrThumbnailUnavailable
}
