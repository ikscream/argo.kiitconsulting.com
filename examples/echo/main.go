// echo is a tiny dependency-free HTTP server that echoes request info as JSON:
// the requested DNS name (Host), client IP (proxy-aware), method, path, headers,
// and which pod served it. Handy for testing ingress/DNS/TLS end to end.
package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

type echoResponse struct {
	Message   string            `json:"message"`
	Timestamp string            `json:"timestamp"`
	Host      string            `json:"host"` // the DNS name the client requested
	Method    string            `json:"method"`
	Path      string            `json:"path"`
	Query     string            `json:"query,omitempty"`
	ClientIP  string            `json:"client_ip"`
	Proto     string            `json:"proto"`
	ServedBy  string            `json:"served_by"` // pod hostname
	UserAgent string            `json:"user_agent,omitempty"`
	Headers   map[string]string `json:"headers"`
}

// clientIP prefers proxy headers (Traefik/Cloudflare sit in front) and falls
// back to the socket peer address.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return strings.TrimSpace(strings.Split(xff, ",")[0])
	}
	if xr := r.Header.Get("X-Real-IP"); xr != "" {
		return xr
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

func main() {
	hostname, _ := os.Hostname()

	mux := http.NewServeMux()
	ok := func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) }
	mux.HandleFunc("/healthz", ok)
	mux.HandleFunc("/readyz", ok)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		headers := make(map[string]string, len(r.Header))
		for k, v := range r.Header {
			headers[k] = strings.Join(v, ", ")
		}
		resp := echoResponse{
			Message:   "echo",
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Host:      r.Host,
			Method:    r.Method,
			Path:      r.URL.Path,
			Query:     r.URL.RawQuery,
			ClientIP:  clientIP(r),
			Proto:     r.Proto,
			ServedBy:  hostname,
			UserAgent: r.UserAgent(),
			Headers:   headers,
		}
		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		_ = enc.Encode(resp)
	})

	addr := ":8080"
	if v := os.Getenv("LISTEN_ADDR"); v != "" {
		addr = v
	}
	log.Printf("echo listening on %s (served_by=%s)", addr, hostname)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.ListenAndServe())
}
