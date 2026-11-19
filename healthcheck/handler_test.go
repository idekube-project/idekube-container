package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"
	"time"
)

func TestBuildHealthResponseMarksSlowServiceUnhealthy(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(healthResponseTimeout + time.Second)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	port := testServerPort(t, server.URL)
	cfg := &HealthConfig{
		Branch: "test",
		Entry:  "/",
		Main:   "slow",
		Services: map[string]ServiceConfig{
			"slow": {
				Port:        port,
				Path:        "/slow",
				ProbePath:   "/",
				ProbeMethod: "http",
			},
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), healthResponseTimeout)
	defer cancel()

	start := time.Now()
	resp, status := buildHealthResponse(ctx, cfg)
	elapsed := time.Since(start)

	if elapsed > healthResponseTimeout+500*time.Millisecond {
		t.Fatalf("health response took %s, expected close to %s", elapsed, healthResponseTimeout)
	}
	if status != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", status, http.StatusBadGateway)
	}
	if resp.Status != "degraded" {
		t.Fatalf("response status = %q, want degraded", resp.Status)
	}
	if resp.Services["slow"].Healthy {
		t.Fatal("slow service was reported healthy")
	}
}

func testServerPort(t *testing.T, rawURL string) int {
	t.Helper()

	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("parse test server URL: %v", err)
	}
	_, portString, err := net.SplitHostPort(parsed.Host)
	if err != nil {
		t.Fatalf("split test server host/port: %v", err)
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		t.Fatalf("parse test server port: %v", err)
	}
	return port
}
