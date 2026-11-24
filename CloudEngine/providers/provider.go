// SPDX-License-Identifier: AGPL-3.0-only
// Filmbox adaptations of OpenList, see ../UPSTREAM.md.
package providers

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"
)

type Entry struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	IsDirectory bool    `json:"is_directory"`
	Size        int64   `json:"size"`
	Modified    string  `json:"modified"`
	Created     string  `json:"created,omitempty"`
	Width       int     `json:"width,omitempty"`
	Height      int     `json:"height,omitempty"`
	Duration    float64 `json:"duration,omitempty"`
	Thumbnail   string  `json:"thumbnail,omitempty"`
}

type Link struct {
	URL       string
	Headers   map[string]string
	ExpiresAt time.Time
}
type Provider interface {
	Name() string
	Root() string
	List(context.Context, string, string) ([]Entry, error)
	Resolve(context.Context, string, string) (Link, error)
	Credential() string
}

type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Message }

var ErrExpired = &Error{"authentication_expired", "登录已过期，请重新连接网盘。"}
var ErrUnavailable = &Error{"provider_unavailable", "暂时无法连接网盘，请稍后重试。"}
var ErrInvalid = &Error{"invalid_request", "连接信息不完整或格式不正确。"}
var ErrNotFound = &Error{"not_found", "文件已移动、删除，或无权访问。"}
var ErrThumbnailUnavailable = &Error{"thumbnail_unavailable", "网盘未提供此文件的封面。"}
var ErrSecure = &Error{"secure_connection_failed", "无法验证云盘连接，请检查服务器证书或系统时间。"}
var ErrNetwork = &Error{"network_unavailable", "无法连接网络，请检查网络连接。"}
var ErrTimeout = &Error{"network_timeout", "连接超时，请检查网络或稍后再试。"}
var ErrDenied = &Error{"access_denied", "云盘拒绝访问，请在网盘中检查文件权限或账户限制。"}
var ErrThrottled = &Error{"rate_limited", "云盘请求过于频繁，已暂停请求，请稍后再试。"}

// Preserve evidence without exposing signed URLs, credentials or upstream bodies.
// A generic 403 is not proof of an expired login.
func StatusError(status int) *Error {
	switch status {
	case 401:
		return ErrExpired
	case 403:
		return ErrDenied
	case 404, 410:
		return ErrNotFound
	case 408, 504:
		return ErrTimeout
	case 429:
		return ErrThrottled
	default:
		return ErrUnavailable
	}
}
func TransportError(err error) error {
	if errors.Is(err, context.Canceled) {
		return context.Canceled
	}
	var certificate *tls.CertificateVerificationError
	var authority x509.UnknownAuthorityError
	var hostname x509.HostnameError
	if errors.As(err, &certificate) || errors.As(err, &authority) || errors.As(err, &hostname) {
		return ErrSecure
	}
	var timeout net.Error
	if errors.Is(err, context.DeadlineExceeded) || errors.As(err, &timeout) && timeout.Timeout() {
		return ErrTimeout
	}
	return ErrNetwork
}

var Client = &http.Client{Timeout: 30 * time.Second}

// Only allow HTTP(S) links. Never expose upstream bodies or request URLs in errors:
// they may contain refresh tokens, cookies or signed download parameters.
func ValidURL(raw string) bool {
	u, e := url.Parse(raw)
	return e == nil && u.Host != "" && (u.Scheme == "https" || u.Scheme == "http") && u.User == nil
}
func DoJSON(ctx context.Context, method, raw string, headers map[string]string, body io.Reader, result any) (*http.Response, error) {
	if !ValidURL(raw) {
		return nil, ErrInvalid
	}
	req, err := http.NewRequestWithContext(ctx, method, raw, body)
	if err != nil {
		return nil, ErrInvalid
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := Client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, TransportError(err)
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return res, StatusError(res.StatusCode)
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 24<<20)).Decode(result); err != nil {
		return res, ErrUnavailable
	}
	return res, nil
}
func TimeSeconds(v int64) string {
	if v <= 0 {
		return time.Unix(0, 0).UTC().Format(time.RFC3339)
	}
	return time.Unix(v, 0).UTC().Format(time.RFC3339)
}
func TimeMillis(v int64) string { return TimeSeconds(v / 1000) }
func SafeError(err error) *Error {
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return ErrTimeout
	}
	return ErrUnavailable
}
