package main

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
)

const healthResponseTimeout = 2 * time.Second

type ServiceStatus struct {
	Port    int    `json:"port"`
	Path    string `json:"path"`
	Healthy bool   `json:"healthy"`
}

type HealthResponse struct {
	Status   string                   `json:"status"`
	Branch   string                   `json:"branch"`
	Entry    string                   `json:"entry"`
	Services map[string]ServiceStatus `json:"services"`
}

func healthHandler(c *gin.Context) {
	cfg, err := loadConfig()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), healthResponseTimeout)
	defer cancel()

	resp, status := buildHealthResponse(ctx, cfg)
	c.Header("Cache-Control", "no-store")
	c.JSON(status, resp)
}

func buildHealthResponse(ctx context.Context, cfg *HealthConfig) (HealthResponse, int) {
	resp := HealthResponse{
		Branch:   cfg.Branch,
		Entry:    cfg.Entry,
		Services: make(map[string]ServiceStatus),
	}

	type result struct {
		name    string
		status  ServiceStatus
		healthy bool
	}

	results := make(map[string]result, len(cfg.Services))
	resultCh := make(chan result, len(cfg.Services))

	for name, svc := range cfg.Services {
		go func(name string, svc ServiceConfig) {
			prober := ProberForMethod(svc.ProbeMethod)
			healthy := prober.Probe(ctx, svc)
			resultCh <- result{
				name:    name,
				status:  ServiceStatus{Port: svc.Port, Path: svc.Path, Healthy: healthy},
				healthy: healthy,
			}
		}(name, svc)
	}

	for remaining := len(cfg.Services); remaining > 0; remaining-- {
		select {
		case r := <-resultCh:
			results[r.name] = r
		case <-ctx.Done():
			remaining = 0
		}
	}

	allHealthy := true
	mainHealthy := true
	for name, svc := range cfg.Services {
		r, ok := results[name]
		if !ok {
			r = result{
				name:    name,
				status:  ServiceStatus{Port: svc.Port, Path: svc.Path, Healthy: false},
				healthy: false,
			}
		}
		resp.Services[r.name] = r.status
		if !r.healthy {
			allHealthy = false
			if r.name == cfg.Main {
				mainHealthy = false
			}
		}
	}

	if allHealthy {
		resp.Status = "healthy"
	} else {
		resp.Status = "degraded"
	}

	if !mainHealthy {
		return resp, http.StatusBadGateway
	}
	return resp, http.StatusOK
}
