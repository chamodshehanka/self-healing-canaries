// loadgen simulates real users hitting the checkout API through the gateway.
//
// The traffic PROFILE is what makes staging and prod different:
//
//	staging: PROFILE="us-east:USD:100"                          RPS=60
//	prod:    PROFILE="us-east:USD:70,eu-west:EUR:20,ap-northeast:JPY:10" RPS=150
//
// Each entry is region:currency:weight. The region goes in X-Region, as a geo-LB would set it.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type segment struct {
	region, currency string
	weight           int
}

func parseProfile(s string) ([]segment, int, error) {
	var segs []segment
	sum := 0
	for _, part := range strings.Split(s, ",") {
		f := strings.Split(strings.TrimSpace(part), ":")
		if len(f) != 3 {
			return nil, 0, fmt.Errorf("bad profile entry %q (want region:currency:weight)", part)
		}
		w, err := strconv.Atoi(f[2])
		if err != nil || w <= 0 {
			return nil, 0, fmt.Errorf("bad weight in %q", part)
		}
		segs = append(segs, segment{f[0], strings.ToUpper(f[1]), w})
		sum += w
	}
	return segs, sum, nil
}

func pick(segs []segment, sum int) segment {
	n := rand.IntN(sum)
	for _, s := range segs {
		if n < s.weight {
			return s
		}
		n -= s.weight
	}
	return segs[len(segs)-1]
}

// amount returns a realistic basket value in major units.
func amount(currency string) float64 {
	switch currency {
	case "JPY", "KRW":
		return float64(800 + rand.IntN(91)*100) // ¥800 – ¥9,800, no decimals
	default:
		return float64(500+rand.IntN(29500)) / 100 // 5.00 – 299.99
	}
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	target := env("TARGET_URL", "http://checkout-gateway.envoy-gateway-system:8080/pay")
	rps, _ := strconv.Atoi(env("RPS", "50"))
	segs, sum, err := parseProfile(env("PROFILE", "us-east:USD:100"))
	if err != nil || rps <= 0 {
		slog.Error("config", "err", err, "rps", rps)
		os.Exit(1)
	}
	slog.Info("loadgen starting", "target", target, "rps", rps, "profile", env("PROFILE", "us-east:USD:100"))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	client := &http.Client{Timeout: 3 * time.Second}

	var mu sync.Mutex
	stats := map[string]int{} // "region/currency status" -> count

	go func() {
		t := time.NewTicker(10 * time.Second)
		for range t.C {
			mu.Lock()
			snapshot := stats
			stats = map[string]int{}
			mu.Unlock()
			slog.Info("last 10s", "results", snapshot)
		}
	}()

	tick := time.NewTicker(time.Second / time.Duration(rps))
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			s := pick(segs, sum)
			go func() {
				body, _ := json.Marshal(map[string]any{
					"sku": fmt.Sprintf("sku-%d", rand.IntN(10)), "qty": 1,
					"amount": amount(s.currency), "currency": s.currency,
				})
				req, _ := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(body))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("X-Region", s.region)
				status := "err"
				if resp, err := client.Do(req); err == nil {
					status = strconv.Itoa(resp.StatusCode)
					resp.Body.Close()
				}
				mu.Lock()
				stats[s.region+"/"+s.currency+" "+status]++
				mu.Unlock()
			}()
		}
	}
}
