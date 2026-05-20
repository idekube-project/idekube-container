package main

import (
	"fmt"
	"net"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

const probeTimeout = 1 * time.Second

type Prober interface {
	Probe(svc ServiceConfig) bool
}

type HTTPProber struct{}

func (p *HTTPProber) Probe(svc ServiceConfig) bool {
	client := &http.Client{Timeout: probeTimeout}
	probePath := svc.ProbePath
	if probePath == "" {
		probePath = "/"
	}
	url := fmt.Sprintf("http://127.0.0.1:%d%s", svc.Port, probePath)
	resp, err := client.Get(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 400
}

type WebSocketProber struct{}

func (p *WebSocketProber) Probe(svc ServiceConfig) bool {
	dialer := websocket.Dialer{
		HandshakeTimeout: probeTimeout,
	}
	probePath := svc.ProbePath
	if probePath == "" {
		probePath = "/"
	}
	url := fmt.Sprintf("ws://127.0.0.1:%d%s", svc.Port, probePath)
	conn, _, err := dialer.Dial(url, nil)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

type TCPProber struct{}

func (p *TCPProber) Probe(svc ServiceConfig) bool {
	addr := fmt.Sprintf("127.0.0.1:%d", svc.Port)
	conn, err := net.DialTimeout("tcp", addr, probeTimeout)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

type FallbackProber struct {
	Probers []Prober
}

func (p *FallbackProber) Probe(svc ServiceConfig) bool {
	for _, prober := range p.Probers {
		if prober.Probe(svc) {
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
