// SPDX-License-Identifier: AGPL-3.0-only
// Filmbox read-only WebDAV transport, for OpenList and other WebDAV servers.
package providers

import (
	"context"
	"encoding/base64"
	"encoding/xml"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

type WebDAV struct {
	endpoint           *url.URL
	username, password string
}

func NewWebDAV(ctx context.Context, endpoint, username, password string) (*WebDAV, error) {
	if !ValidURL(endpoint) {
		return nil, ErrInvalid
	}
	u, _ := url.Parse(endpoint)
	u.RawQuery, u.Fragment = "", ""
	u.Path = strings.TrimRight(u.Path, "/") + "/"
	u.RawPath = ""
	w := &WebDAV{u, username, password}
	if _, err := w.List(ctx, "/", "/"); err != nil {
		return nil, err
	}
	return w, nil
}
func (w *WebDAV) Name() string       { return w.endpoint.Hostname() }
func (w *WebDAV) Root() string       { return "/" }
func (w *WebDAV) Credential() string { return "" }
func (w *WebDAV) assetURL(rawPath string) *url.URL {
	u := *w.endpoint
	rawPath = "/" + strings.TrimLeft(rawPath, "/")
	u.Path = strings.TrimRight(w.endpoint.Path, "/") + path.Clean(rawPath)
	u.RawPath = ""
	return &u
}
func (w *WebDAV) headers() map[string]string {
	h := map[string]string{}
	if w.username != "" || w.password != "" {
		h["Authorization"] = "Basic " + base64.StdEncoding.EncodeToString([]byte(w.username+":"+w.password))
	}
	return h
}
func (w *WebDAV) List(ctx context.Context, folderID, folderPath string) ([]Entry, error) {
	if folderPath == "" {
		folderPath = folderID
	}
	if folderPath == "" {
		folderPath = "/"
	}
	target := w.assetURL(folderPath)
	if !strings.HasSuffix(target.Path, "/") {
		target.Path += "/"
	}
	body := `<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:creationdate/></d:prop></d:propfind>`
	req, _ := http.NewRequestWithContext(ctx, "PROPFIND", target.String(), strings.NewReader(body))
	for k, v := range w.headers() {
		req.Header.Set(k, v)
	}
	req.Header.Set("Depth", "1")
	req.Header.Set("Content-Type", "application/xml; charset=utf-8")
	res, err := Client.Do(req)
	if err != nil {
		return nil, TransportError(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 207 && res.StatusCode != 200 {
		return nil, StatusError(res.StatusCode)
	}
	var response struct {
		Responses []struct {
			Href      string `xml:"href"`
			Status    string `xml:"status"`
			Propstats []struct {
				Status string `xml:"status"`
				Prop   struct {
					DisplayName string `xml:"displayname"`
					Type        struct {
						Collection *struct{} `xml:"collection"`
					} `xml:"resourcetype"`
					Size     string `xml:"getcontentlength"`
					Modified string `xml:"getlastmodified"`
					Created  string `xml:"creationdate"`
				} `xml:"prop"`
			} `xml:"propstat"`
		} `xml:"response"`
	}
	if xml.NewDecoder(io.LimitReader(res.Body, 24<<20)).Decode(&response) != nil {
		return nil, ErrUnavailable
	}
	entries := make([]Entry, 0)
	rootPath := strings.TrimRight(w.endpoint.Path, "/")
	current := path.Clean(target.Path)
	for _, r := range response.Responses {
		for _, code := range []int{401, 403, 404, 429, 503} {
			if strings.Contains(r.Status, " "+strconv.Itoa(code)+" ") {
				return nil, StatusError(code)
			}
		}
		hasReadable := false
		for _, p := range r.Propstats {
			if p.Status == "" || strings.Contains(p.Status, " 200 ") {
				hasReadable = true
			}
		}
		if !hasReadable {
			for _, p := range r.Propstats {
				if strings.Contains(p.Status, " 403 ") {
					return nil, ErrDenied
				}
				if strings.Contains(p.Status, " 401 ") {
					return nil, ErrExpired
				}
			}
		}
		href, err := url.Parse(r.Href)
		if err != nil {
			continue
		}
		if href.IsAbs() && href.Host != target.Host {
			continue
		}
		fullPath := href.Path
		if !strings.HasPrefix(fullPath, "/") {
			fullPath = target.ResolveReference(href).Path
		}
		fullPath = path.Clean(fullPath)
		if fullPath == current || !strings.HasPrefix(fullPath, rootPath+"/") {
			continue
		}
		relative := strings.TrimPrefix(fullPath, rootPath)
		if path.Dir(relative) != path.Clean("/"+strings.TrimLeft(folderPath, "/")) {
			continue
		}
		for _, p := range r.Propstats {
			if !strings.Contains(p.Status, " 200 ") && p.Status != "" {
				continue
			}
			f := p.Prop
			name := f.DisplayName
			if name == "" {
				name = path.Base(fullPath)
			}
			size, _ := strconv.ParseInt(f.Size, 10, 64)
			mtime, err := http.ParseTime(f.Modified)
			if err != nil {
				mtime = time.Unix(0, 0)
			}
			created := ""
			if c, err := time.Parse(time.RFC3339, f.Created); err == nil {
				created = c.UTC().Format(time.RFC3339)
			}
			entries = append(entries, Entry{ID: relative, Name: name, IsDirectory: f.Type.Collection != nil, Size: size, Modified: mtime.UTC().Format(time.RFC3339), Created: created})
			break
		}
	}
	return entries, nil
}
func (w *WebDAV) Resolve(_ context.Context, fileID, filePath string) (Link, error) {
	if filePath == "" {
		filePath = fileID
	}
	if filePath == "" {
		return Link{}, ErrInvalid
	}
	return Link{URL: w.assetURL(filePath).String(), Headers: w.headers()}, nil
}
