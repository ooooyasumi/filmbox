// SPDX-License-Identifier: AGPL-3.0-only
// Derived from OpenList drivers/baidu_netdisk/{util,types,driver,meta}.go,
// commit e72822f5390f4272c9fe9da8cabba3c1a270182f, copyright OpenList contributors.
// Filmbox: read-only extraction; standard-library transport; bounded pagination;
// credential updates are returned to the Keychain owner, never stored on disk.
package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

type BaiduCredential struct {
	AccessToken  string `json:"access_token,omitempty"`
	RefreshToken string `json:"refresh_token,omitempty"`
	ClientID     string `json:"client_id,omitempty"`
	ClientSecret string `json:"client_secret,omitempty"`
}
type Baidu struct {
	credential     BaiduCredential
	api, onlineAPI string
	name           string
}

func NewBaidu(ctx context.Context, credential string) (*Baidu, error) {
	b := &Baidu{api: "https://pan.baidu.com/rest/2.0", onlineAPI: "https://api.oplist.org/baiduyun/renewapi", name: "百度网盘"}
	if strings.HasPrefix(strings.TrimSpace(credential), "{") {
		if json.Unmarshal([]byte(credential), &b.credential) != nil {
			return nil, ErrInvalid
		}
	} else {
		b.credential.RefreshToken = strings.TrimSpace(credential)
	}
	if b.credential.AccessToken == "" && b.credential.RefreshToken == "" {
		return nil, ErrInvalid
	}
	if (b.credential.ClientID == "") != (b.credential.ClientSecret == "") {
		return nil, ErrInvalid
	}
	if b.credential.AccessToken == "" {
		if err := b.refresh(ctx); err != nil {
			return nil, err
		}
	}
	var info struct {
		Errno    int             `json:"errno"`
		Name     string          `json:"netdisk_name"`
		Username string          `json:"baidu_name"`
		UK       json.RawMessage `json:"uk"`
	}
	if err := b.get(ctx, "/xpan/nas", url.Values{"method": {"uinfo"}}, &info); err != nil {
		return nil, err
	}
	if info.Name == "" && info.Username == "" && (len(info.UK) == 0 || string(info.UK) == "0") {
		return nil, ErrExpired
	}
	if info.Name != "" {
		b.name = info.Name
	} else if info.Username != "" {
		b.name = info.Username
	}
	return b, nil
}
func (b *Baidu) Name() string       { return b.name }
func (b *Baidu) Root() string       { return "/" }
func (b *Baidu) Credential() string { data, _ := json.Marshal(b.credential); return string(data) }
func (b *Baidu) refresh(ctx context.Context) error {
	if b.credential.RefreshToken == "" {
		return ErrExpired
	}
	u := b.onlineAPI
	query := url.Values{"refresh_ui": {b.credential.RefreshToken}, "server_use": {"true"}, "driver_txt": {"baiduyun_go"}}
	if b.credential.ClientID != "" {
		u = "https://openapi.baidu.com/oauth/2.0/token"
		query = url.Values{"grant_type": {"refresh_token"}, "refresh_token": {b.credential.RefreshToken}, "client_id": {b.credential.ClientID}, "client_secret": {b.credential.ClientSecret}}
	}
	var response struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		Error        string `json:"error"`
	}
	_, err := DoJSON(ctx, http.MethodGet, u+"?"+query.Encode(), nil, nil, &response)
	if err != nil {
		return err
	}
	if response.Error == "invalid_grant" || response.Error == "invalid_token" || response.Error == "expired_token" || response.Error == "invalid_refresh_token" {
		return ErrExpired
	}
	if response.Error != "" || response.AccessToken == "" || response.RefreshToken == "" {
		return ErrUnavailable
	}
	b.credential.AccessToken, b.credential.RefreshToken = response.AccessToken, response.RefreshToken
	return nil
}
func (b *Baidu) get(ctx context.Context, endpoint string, params url.Values, result any) error {
	for attempt := 0; attempt < 2; attempt++ {
		params.Set("access_token", b.credential.AccessToken)
		var raw json.RawMessage
		_, err := DoJSON(ctx, http.MethodGet, b.api+endpoint+"?"+params.Encode(), nil, nil, &raw)
		if err != nil {
			return err
		}
		var response struct {
			Errno int `json:"errno"`
		}
		if json.Unmarshal(raw, &response) != nil {
			return ErrUnavailable
		}
		switch response.Errno {
		case 0:
			if json.Unmarshal(raw, result) != nil {
				return ErrUnavailable
			}
			return nil
		case 111, -6, 20016, 20017:
			if attempt == 1 {
				return ErrExpired
			}
			if err := b.refresh(ctx); err != nil {
				return err
			}
		case -9, 12:
			return ErrNotFound
		default:
			return &Error{"provider_error", fmt.Sprintf("百度网盘暂时无法完成请求（%d）。", response.Errno)}
		}
	}
	return ErrExpired
}

type baiduFile struct {
	ID            int64   `json:"fs_id"`
	Name          string  `json:"server_filename"`
	Path          string  `json:"path"`
	Size          int64   `json:"size"`
	IsDir         int     `json:"isdir"`
	Modified      int64   `json:"server_mtime"`
	Created       int64   `json:"server_ctime"`
	LocalModified int64   `json:"local_mtime"`
	LocalCreated  int64   `json:"local_ctime"`
	Width         int     `json:"width"`
	Height        int     `json:"height"`
	Duration      float64 `json:"duration"`
	Thumbs        struct {
		URL3 string `json:"url3"`
	} `json:"thumbs"`
}

func (b *Baidu) List(ctx context.Context, folderID, folderPath string) ([]Entry, error) {
	if folderPath == "" {
		folderPath = folderID
	}
	if folderPath == "" {
		folderPath = "/"
	}
	params := url.Values{"method": {"list"}, "dir": {folderPath}, "web": {"web"}, "order": {"name"}, "limit": {"1000"}}
	entries := make([]Entry, 0)
	for start := 0; start < 1000000; start += 1000 {
		params.Set("start", strconv.Itoa(start))
		var response struct {
			List []baiduFile `json:"list"`
		}
		if err := b.get(ctx, "/xpan/file", params, &response); err != nil {
			return nil, err
		}
		for _, f := range response.List {
			if f.ID == 0 {
				continue
			}
			if f.Name == "" {
				f.Name = path.Base(f.Path)
			}
			mtime, ctime := f.Modified, f.Created
			if f.LocalModified > 0 {
				mtime = f.LocalModified
			}
			if f.LocalCreated > 0 {
				ctime = f.LocalCreated
			}
			entries = append(entries, Entry{ID: strconv.FormatInt(f.ID, 10), Name: f.Name, IsDirectory: f.IsDir == 1, Size: f.Size, Modified: TimeSeconds(mtime), Created: TimeSeconds(ctime), Width: f.Width, Height: f.Height, Duration: f.Duration, Thumbnail: f.Thumbs.URL3})
		}
		if len(response.List) < 1000 {
			return entries, nil
		}
	}
	return nil, &Error{"folder_too_large", "此文件夹项目过多，请选择更具体的子文件夹。"}
}
func (b *Baidu) Resolve(ctx context.Context, fileID, _ string) (Link, error) {
	if _, err := strconv.ParseUint(fileID, 10, 64); err != nil {
		return Link{}, ErrInvalid
	}
	var response struct {
		List []struct {
			URL string `json:"dlink"`
		} `json:"list"`
	}
	params := url.Values{"method": {"filemetas"}, "fsids": {"[" + fileID + "]"}, "dlink": {"1"}, "extra": {"1"}}
	if err := b.get(ctx, "/xpan/multimedia", params, &response); err != nil {
		return Link{}, err
	}
	if len(response.List) == 0 || !ValidURL(response.List[0].URL) {
		return Link{}, ErrNotFound
	}
	u, _ := url.Parse(response.List[0].URL)
	query := u.Query()
	query.Set("access_token", b.credential.AccessToken)
	u.RawQuery = query.Encode()
	// OpenList follows the official dlink HEAD redirect before playback. A 200
	// endpoint is usable too; do not replace it with an empty Location header.
	req, _ := http.NewRequestWithContext(ctx, http.MethodHead, u.String(), nil)
	req.Header.Set("User-Agent", "pan.baidu.com")
	client := *Client
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	res, err := client.Do(req)
	if err != nil {
		return Link{}, ErrUnavailable
	}
	res.Body.Close()
	resolved := u.String()
	if res.StatusCode >= 300 && res.StatusCode < 400 {
		target, err := u.Parse(res.Header.Get("Location"))
		if err != nil || !ValidURL(target.String()) {
			return Link{}, ErrUnavailable
		}
		resolved = target.String()
	} else if res.StatusCode == 401 || res.StatusCode == 403 {
		return Link{}, ErrExpired
	} else if res.StatusCode < 200 || res.StatusCode >= 300 {
		return Link{}, ErrUnavailable
	}
	return Link{URL: resolved, Headers: map[string]string{"User-Agent": "pan.baidu.com"}, ExpiresAt: time.Now().Add(time.Hour)}, nil
}
func (b *Baidu) Thumbnail(ctx context.Context, fileID, filePath string) (Link, bool, error) {
	if _, err := strconv.ParseUint(fileID, 10, 64); err != nil {
		return Link{}, false, ErrInvalid
	}
	var response struct {
		List []struct {
			Thumbs struct {
				URL3 string `json:"url3"`
				URL2 string `json:"url2"`
				URL1 string `json:"url1"`
			} `json:"thumbs"`
		} `json:"list"`
	}
	if err := b.get(ctx, "/xpan/multimedia", url.Values{"method": {"filemetas"}, "fsids": {"[" + fileID + "]"}, "extra": {"1"}, "thumb": {"1"}}, &response); err != nil {
		return Link{}, false, err
	}
	if len(response.List) > 0 {
		thumbs := response.List[0].Thumbs
		for _, raw := range []string{thumbs.URL3, thumbs.URL2, thumbs.URL1} {
			if ValidURL(raw) {
				return Link{URL: raw, Headers: map[string]string{"User-Agent": "pan.baidu.com"}, ExpiresAt: time.Now().Add(10 * time.Minute)}, true, nil
			}
		}
	}
	return Link{}, false, ErrThumbnailUnavailable
}
