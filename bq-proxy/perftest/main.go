package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

type flags struct {
	proxyURL    string
	directURL   string
	projectID   string
	keysDir     string
	concurrency int
	duration    time.Duration
	scenario    string
	output      string
	skipDirect  bool
}

// tokenPool provides round-robin access to multiple OAuth2 token sources
// so concurrent workers spread across different service accounts and avoid
// BigQuery's per-user 100 req/s quota limit.
type tokenPool struct {
	sources []oauth2.TokenSource
	labels  []string
	counter uint64
}

func newTokenPool(keysDir string) (*tokenPool, error) {
	if keysDir == "" {
		ts, label, err := adcTokenSource()
		if err != nil {
			return nil, err
		}
		return &tokenPool{sources: []oauth2.TokenSource{ts}, labels: []string{label}}, nil
	}

	matches, err := filepath.Glob(filepath.Join(keysDir, "*.json"))
	if err != nil {
		return nil, fmt.Errorf("scanning keys dir: %w", err)
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("no .json key files found in %s", keysDir)
	}

	pool := &tokenPool{}
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", path, err)
		}
		creds, err := google.CredentialsFromJSON(context.Background(), data, "https://www.googleapis.com/auth/bigquery")
		if err != nil {
			return nil, fmt.Errorf("parsing %s: %w", path, err)
		}
		pool.sources = append(pool.sources, creds.TokenSource)
		pool.labels = append(pool.labels, filepath.Base(path))
	}
	fmt.Printf("Loaded %d service account key(s) from %s\n", len(pool.sources), keysDir)
	for _, l := range pool.labels {
		fmt.Printf("  - %s\n", l)
	}
	return pool, nil
}

func adcTokenSource() (oauth2.TokenSource, string, error) {
	creds, err := google.FindDefaultCredentials(context.Background(), "https://www.googleapis.com/auth/bigquery")
	if err != nil {
		return nil, "", fmt.Errorf("finding default credentials: %w", err)
	}
	return creds.TokenSource, "application-default", nil
}

func (tp *tokenPool) getToken() (string, error) {
	idx := atomic.AddUint64(&tp.counter, 1) - 1
	src := tp.sources[idx%uint64(len(tp.sources))]
	tok, err := src.Token()
	if err != nil {
		return "", err
	}
	return tok.AccessToken, nil
}

func (tp *tokenPool) size() int {
	return len(tp.sources)
}

type scenario struct {
	name  string
	query string
}

var scenarios = map[string][]scenario{
	"small": {
		{name: "select_1", query: "SELECT 1"},
		{name: "generate_array", query: "SELECT * FROM UNNEST(GENERATE_ARRAY(1, 100)) AS n"},
	},
	"medium": {
		{name: "shakespeare_1k", query: "SELECT word, word_count FROM `bigquery-public-data.samples.shakespeare` LIMIT 1000"},
	},
	"large": {
		{name: "shakespeare_full", query: "SELECT * FROM `bigquery-public-data.samples.shakespeare`"},
		{name: "natality_100k", query: "SELECT * FROM `bigquery-public-data.samples.natality` LIMIT 100000"},
	},
}

type result struct {
	latency time.Duration
	bytes   int64
	err     error
}

type stats struct {
	count      int
	errors     int
	p50        time.Duration
	p95        time.Duration
	p99        time.Duration
	totalBytes int64
	totalTime  time.Duration
}

func main() {
	f := parseFlags()

	pool, err := newTokenPool(f.keysDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize token pool: %v\n", err)
		os.Exit(1)
	}

	selectedScenarios := buildScenarioList(f.scenario)

	for _, group := range selectedScenarios {
		for _, sc := range group.scenarios {
			fmt.Printf("\n--- Scenario: %s (%s) [1 warmup + N measured runs] ---\n", sc.name, group.name)

			if group.name == "large" {
				runStreamingTest(f, sc, pool)
			} else {
				runLatencyTest(f, sc, pool)
			}
		}
	}

	if f.scenario == "all" || f.scenario == "concurrent" {
		fmt.Printf("\n--- Scenario: concurrent_load ---\n")
		sc := scenario{name: "concurrent_select_1", query: "SELECT 1"}
		concLevels := []int{10, 50, 100}
		if f.concurrency != 10 {
			concLevels = []int{f.concurrency}
		}
		for _, conc := range concLevels {
			f.concurrency = conc
			runConcurrentTest(f, sc, pool)
		}
	}
}

func parseFlags() *flags {
	f := &flags{}
	flag.StringVar(&f.proxyURL, "proxy-url", "http://localhost:8080", "URL of the proxy")
	flag.StringVar(&f.directURL, "direct-url", "https://bigquery.googleapis.com", "Direct BQ API URL")
	flag.StringVar(&f.projectID, "project-id", "", "GCP project for billing (required)")
	flag.IntVar(&f.concurrency, "concurrency", 10, "Number of concurrent workers")
	flag.DurationVar(&f.duration, "duration", 30*time.Second, "Test duration for concurrent tests")
	flag.StringVar(&f.scenario, "scenario", "all", "Test scenario: small|medium|large|concurrent|all")
	flag.StringVar(&f.keysDir, "keys-dir", "", "Directory with service account JSON key files for round-robin auth (uses ADC if empty)")
	flag.StringVar(&f.output, "output", "text", "Output format: text|json")
	flag.BoolVar(&f.skipDirect, "proxy-only", false, "Skip direct BQ calls, test only via proxy")
	flag.Parse()

	if f.projectID == "" {
		fmt.Fprintln(os.Stderr, "Error: --project-id is required")
		flag.Usage()
		os.Exit(1)
	}
	return f
}

type scenarioGroup struct {
	name      string
	scenarios []scenario
}

func buildScenarioList(filter string) []scenarioGroup {
	if filter == "all" || filter == "" {
		var groups []scenarioGroup
		for _, name := range []string{"small", "medium", "large"} {
			groups = append(groups, scenarioGroup{name: name, scenarios: scenarios[name]})
		}
		return groups
	}
	if filter == "concurrent" {
		return nil
	}
	if sc, ok := scenarios[filter]; ok {
		return []scenarioGroup{{name: filter, scenarios: sc}}
	}
	fmt.Fprintf(os.Stderr, "Unknown scenario: %s\n", filter)
	os.Exit(1)
	return nil
}

func runLatencyTest(f *flags, sc scenario, pool *tokenPool) {
	const iterations = 20

	var directStats stats
	if !f.skipDirect {
		directResults := runIterations(f.directURL, f.projectID, sc.query, pool, iterations)
		directStats = computeStats(directResults)
		fmt.Printf("  Direct BQ:  p50=%v  p95=%v  p99=%v  errors=%d/%d\n",
			directStats.p50.Round(time.Millisecond),
			directStats.p95.Round(time.Millisecond),
			directStats.p99.Round(time.Millisecond),
			directStats.errors, directStats.count)
	}

	proxyResults := runIterations(f.proxyURL, f.projectID, sc.query, pool, iterations)
	proxyStats := computeStats(proxyResults)
	fmt.Printf("  Via Proxy:  p50=%v  p95=%v  p99=%v  errors=%d/%d\n",
		proxyStats.p50.Round(time.Millisecond),
		proxyStats.p95.Round(time.Millisecond),
		proxyStats.p99.Round(time.Millisecond),
		proxyStats.errors, proxyStats.count)

	if !f.skipDirect {
		fmt.Printf("  Overhead:   p50=%v  p95=%v  p99=%v\n",
			(proxyStats.p50 - directStats.p50).Round(time.Millisecond),
			(proxyStats.p95 - directStats.p95).Round(time.Millisecond),
			(proxyStats.p99 - directStats.p99).Round(time.Millisecond))
	}
}

func runStreamingTest(f *flags, sc scenario, pool *tokenPool) {
	const iterations = 3
	var memBefore, memAfter runtime.MemStats

	if !f.skipDirect {
		runtime.GC()
		runtime.ReadMemStats(&memBefore)
		directResults := runIterations(f.directURL, f.projectID, sc.query, pool, iterations)
		runtime.GC()
		runtime.ReadMemStats(&memAfter)
		directStats := computeStats(directResults)
		directPeakMem := memAfter.TotalAlloc - memBefore.TotalAlloc
		fmt.Printf("  Direct BQ:  transfer=%v  bytes=%s  peak_alloc=%s  errors=%d/%d\n",
			directStats.p50.Round(time.Millisecond),
			formatBytes(directStats.totalBytes/int64(iterations)),
			formatBytes(int64(directPeakMem)),
			directStats.errors, directStats.count)
	}

	runtime.GC()
	runtime.ReadMemStats(&memBefore)
	proxyResults := runIterations(f.proxyURL, f.projectID, sc.query, pool, iterations)
	runtime.GC()
	runtime.ReadMemStats(&memAfter)
	proxyStats := computeStats(proxyResults)
	proxyPeakMem := memAfter.TotalAlloc - memBefore.TotalAlloc
	fmt.Printf("  Via Proxy:  transfer=%v  bytes=%s  peak_alloc=%s  errors=%d/%d\n",
		proxyStats.p50.Round(time.Millisecond),
		formatBytes(proxyStats.totalBytes/int64(iterations)),
		formatBytes(int64(proxyPeakMem)),
		proxyStats.errors, proxyStats.count)
}

func runConcurrentTest(f *flags, sc scenario, pool *tokenPool) {
	fmt.Printf("\n  concurrency=%d  duration=%v  identities=%d\n", f.concurrency, f.duration, pool.size())

	var directStats stats
	if !f.skipDirect {
		directStats = runConcurrentLoad(f.directURL, f.projectID, sc.query, pool, f.concurrency, f.duration)
		directThroughput := float64(directStats.count) / f.duration.Seconds()
		fmt.Printf("  Direct BQ:  p50=%v  p95=%v  p99=%v  throughput=%.1f req/s  errors=%d/%d\n",
			directStats.p50.Round(time.Millisecond),
			directStats.p95.Round(time.Millisecond),
			directStats.p99.Round(time.Millisecond),
			directThroughput, directStats.errors, directStats.count)
	}

	proxyStats := runConcurrentLoad(f.proxyURL, f.projectID, sc.query, pool, f.concurrency, f.duration)
	proxyThroughput := float64(proxyStats.count) / f.duration.Seconds()
	fmt.Printf("  Via Proxy:  p50=%v  p95=%v  p99=%v  throughput=%.1f req/s  errors=%d/%d\n",
		proxyStats.p50.Round(time.Millisecond),
		proxyStats.p95.Round(time.Millisecond),
		proxyStats.p99.Round(time.Millisecond),
		proxyThroughput, proxyStats.errors, proxyStats.count)

	if !f.skipDirect {
		directThroughput := float64(directStats.count) / f.duration.Seconds()
		overheadPct := (proxyThroughput - directThroughput) / directThroughput * 100
		fmt.Printf("  Overhead:   p50=%v  p95=%v  throughput=%.1f%%\n",
			(proxyStats.p50 - directStats.p50).Round(time.Millisecond),
			(proxyStats.p95 - directStats.p95).Round(time.Millisecond),
			overheadPct)
	}
}

func runIterations(baseURL, projectID, query string, pool *tokenPool, n int) []result {
	// Warmup: first BQ execution is uncached and would skew percentiles.
	executeQuery(baseURL, projectID, query, pool)

	results := make([]result, 0, n)
	for i := 0; i < n; i++ {
		r := executeQuery(baseURL, projectID, query, pool)
		results = append(results, r)
	}
	return results
}

func runConcurrentLoad(baseURL, projectID, query string, pool *tokenPool, concurrency int, duration time.Duration) stats {
	var (
		mu      sync.Mutex
		results []result
		done    int64
	)

	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()

	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				default:
				}
				r := executeQuery(baseURL, projectID, query, pool)
				mu.Lock()
				results = append(results, r)
				mu.Unlock()
				atomic.AddInt64(&done, 1)
			}
		}()
	}

	wg.Wait()
	return computeStats(results)
}

func executeQuery(baseURL, projectID, query string, pool *tokenPool) result {
	token, err := pool.getToken()
	if err != nil {
		return result{err: fmt.Errorf("getting token: %w", err)}
	}

	url := fmt.Sprintf("%s/bigquery/v2/projects/%s/queries", baseURL, projectID)

	body := map[string]any{
		"query":        query,
		"useLegacySql": false,
	}
	bodyBytes, _ := json.Marshal(body)

	req, err := http.NewRequest("POST", url, bytes.NewReader(bodyBytes))
	if err != nil {
		return result{err: err}
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	start := time.Now()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return result{latency: time.Since(start), err: err}
	}

	n, _ := io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	latency := time.Since(start)

	if resp.StatusCode >= 400 {
		return result{latency: latency, bytes: n, err: fmt.Errorf("HTTP %d", resp.StatusCode)}
	}

	return result{latency: latency, bytes: n}
}

func computeStats(results []result) stats {
	if len(results) == 0 {
		return stats{}
	}

	s := stats{count: len(results)}
	latencies := make([]time.Duration, 0, len(results))

	for _, r := range results {
		if r.err != nil {
			s.errors++
		}
		latencies = append(latencies, r.latency)
		s.totalBytes += r.bytes
		s.totalTime += r.latency
	}

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	s.p50 = percentile(latencies, 0.50)
	s.p95 = percentile(latencies, 0.95)
	s.p99 = percentile(latencies, 0.99)

	return s
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(float64(len(sorted)-1) * p)
	return sorted[idx]
}

func formatBytes(b int64) string {
	const (
		kb = 1024
		mb = kb * 1024
		gb = mb * 1024
	)
	switch {
	case b >= gb:
		return fmt.Sprintf("%.1fGB", float64(b)/float64(gb))
	case b >= mb:
		return fmt.Sprintf("%.1fMB", float64(b)/float64(mb))
	case b >= kb:
		return fmt.Sprintf("%.1fKB", float64(b)/float64(kb))
	default:
		return fmt.Sprintf("%dB", b)
	}
}

func init() {
	// Suppress usage of proxy env vars for the test client itself
	for _, env := range []string{"HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"} {
		os.Unsetenv(env)
	}
}

