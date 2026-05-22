package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

const probeTimeout = 2 * time.Second

type Prober interface {
	Probe(ctx context.Context, svc ServiceConfig) bool
}

type HTTPProber struct{}

func (p *HTTPProber) Probe(ctx context.Context, svc ServiceConfig) bool {
	client := &http.Client{Timeout: probeTimeout}
	probePath := svc.ProbePath
	if probePath == "" {
		probePath = "/"
	}
	url := fmt.Sprintf("http://127.0.0.1:%d%s", svc.Port, probePath)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 400
}

type WebSocketProber struct{}

func (p *WebSocketProber) Probe(ctx context.Context, svc ServiceConfig) bool {
	dialer := websocket.Dialer{
		HandshakeTimeout: probeTimeout,
	}
	probePath := svc.ProbePath
	if probePath == "" {
		probePath = "/"
	}
	url := fmt.Sprintf("ws://127.0.0.1:%d%s", svc.Port, probePath)
	conn, _, err := dialer.DialContext(ctx, url, nil)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

type TCPProber struct{}

func (p *TCPProber) Probe(ctx context.Context, svc ServiceConfig) bool {
	addr := fmt.Sprintf("127.0.0.1:%d", svc.Port)
	dialer := net.Dialer{Timeout: probeTimeout}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

type FallbackProber struct {
	Probers []Prober
}

func (p *FallbackProber) Probe(ctx context.Context, svc ServiceConfig) bool {
	for _, prober := range p.Probers {
		if ctx.Err() != nil {
			return false
		}
		if prober.Probe(ctx, svc) {
			return true
		}
	}
	return false
}

func ProberForMethod(method string) Prober {
	switch method {
	case "tcp":
		return &TCPProber{}
	case "ws", "websocket":
		return &WebSocketProber{}
	case "http":
		return &HTTPProber{}
	default:
		return &FallbackProber{
			Probers: []Prober{
				&HTTPProber{},
				&WebSocketProber{},
			},
		}
	}
}
