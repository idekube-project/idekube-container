package main

import (
	"net/http"
	"sync"

	"github.com/gin-gonic/gin"
)

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

	results := make([]result, 0, len(cfg.Services))
	var mu sync.Mutex
	var wg sync.WaitGroup

	for name, svc := range cfg.Services {
		wg.Add(1)
		go func(name string, svc ServiceConfig) {
			defer wg.Done()
			prober := ProberForMethod(svc.ProbeMethod)
			healthy := prober.Probe(svc)
			mu.Lock()
			results = append(results, result{
				name:    name,
				status:  ServiceStatus{Port: svc.Port, Path: svc.Path, Healthy: healthy},
				healthy: healthy,
			})
			mu.Unlock()
		}(name, svc)
	}
	wg.Wait()

	allHealthy := true
	mainHealthy := true
	for _, r := range results {
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

	c.Header("Cache-Control", "no-store")

	if !mainHealthy {
		c.JSON(http.StatusBadGateway, resp)
		return
	}
	c.JSON(http.StatusOK, resp)
}
