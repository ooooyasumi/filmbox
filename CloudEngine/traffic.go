// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"crypto/rand"
	"encoding/hex"
	"filmbox.local/cloudengine/providers"
	"io"
	"net/http"
	"sync"
	"time"
)

// Count only bytes read from the provider, including cancelled/ranged streams.
// The app's second hop from this loopback proxy must never be added again.
type trafficStats struct {
	mu       sync.Mutex
	session  string
	received int64
	active   int
	days     map[string]int64
}

func newTrafficStats() *trafficStats {
	var id [16]byte
	_, _ = rand.Read(id[:])
	return &trafficStats{session: hex.EncodeToString(id[:]), days: make(map[string]int64)}
}
func (s *trafficStats) record(bytes int) {
	if bytes <= 0 {
		return
	}
	s.mu.Lock()
	s.received += int64(bytes)
	s.days[time.Now().Format("2006-01-02")] += int64(bytes)
	s.mu.Unlock()
}
func (s *trafficStats) begin() { s.mu.Lock(); s.active++; s.mu.Unlock() }
func (s *trafficStats) end()   { s.mu.Lock(); s.active--; s.mu.Unlock() }

type trafficReader struct {
	io.Reader
	stats *trafficStats
}

func (r *trafficReader) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	r.stats.record(n)
	return n, err
}
func (s *server) traffic(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeError(w, 405, providers.ErrInvalid)
		return
	}
	t := s.trafficStats
	t.mu.Lock()
	days := make(map[string]int64, len(t.days))
	for day, bytes := range t.days {
		days[day] = bytes
	}
	total, active, session := t.received, t.active, t.session
	t.mu.Unlock()
	writeJSON(w, 200, map[string]any{"session_id": session, "received_bytes": total, "received_by_day": days, "active_streams": active})
}
