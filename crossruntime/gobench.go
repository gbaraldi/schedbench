// Task launch/latency microbenchmarks, shaped to match the Julia ones.
// go run gobench.go   (set GOMAXPROCS to match julia -t)
package main

import (
	"fmt"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

func benchNs(f func()) float64 {
	f()
	f()
	inner := 1
	t0 := time.Now()
	f()
	t := time.Since(t0).Seconds()
	for t*float64(inner) < 2e-3 {
		inner *= 2
		t0 = time.Now()
		for i := 0; i < inner; i++ {
			f()
		}
		t = time.Since(t0).Seconds() / float64(inner)
	}
	best := 1e18
	for r := 0; r < 5; r++ {
		t0 = time.Now()
		for i := 0; i < inner; i++ {
			f()
		}
		v := time.Since(t0).Seconds() / float64(inner)
		if v < best {
			best = v
		}
	}
	return best * 1e9
}

func main() {
	nt := runtime.GOMAXPROCS(0)
	fmt.Printf("# GOMAXPROCS=%d\n", nt)

	// 1. spawn+join round trip: one goroutine, signal completion
	done := make(chan struct{})
	spawnWait := func() {
		go func() { done <- struct{}{} }()
		<-done
	}
	fmt.Printf("RESULT spawn_wait %.1f\n", benchNs(spawnWait))

	// 2. spawn 100k trivial goroutines, join with WaitGroup
	spawnMany := func() {
		var wg sync.WaitGroup
		var c atomic.Int64
		wg.Add(100000)
		for i := 0; i < 100000; i++ {
			go func() { c.Add(1); wg.Done() }()
		}
		wg.Wait()
	}
	fmt.Printf("RESULT spawn_many_100k_ms %.2f\n", benchNs(spawnMany)/1e6)

	// 3. unbuffered-channel ping-pong, 10k round trips
	pingpong := func() {
		c1 := make(chan int)
		c2 := make(chan int)
		go func() {
			for i := 0; i < 10000; i++ {
				c2 <- <-c1
			}
		}()
		for i := 0; i < 10000; i++ {
			c1 <- i
			<-c2
		}
	}
	fmt.Printf("RESULT pingpong_10k_ms %.2f\n", benchNs(pingpong)/1e6)

	// 4. fan-out/join region: NT goroutines each doing a trivial chunk
	region := func() {
		var wg sync.WaitGroup
		wg.Add(nt)
		for c := 0; c < nt; c++ {
			go func() { wg.Done() }()
		}
		wg.Wait()
	}
	fmt.Printf("RESULT region_NT %.1f\n", benchNs(region))

	// 5. goroutine-per-node fib(24)
	var fib func(n int) int
	fib = func(n int) int {
		if n <= 1 {
			return n
		}
		ch := make(chan int, 1)
		go func() { ch <- fib(n - 2) }()
		r := fib(n - 1)
		return r + <-ch
	}
	t0 := time.Now()
	fib(24)
	f1 := time.Since(t0).Seconds()
	t0 = time.Now()
	fib(24)
	f2 := time.Since(t0).Seconds()
	fmt.Printf("RESULT fib24_ms %.2f\n", 1e3*min(f1, f2))

	// 6. wake latency distribution: sleeping consumer woken by producer
	lat := make([]float64, 0, 2000)
	c := make(chan int64)
	res := make(chan struct{})
	go func() {
		for t := range c {
			lat = append(lat, float64(time.Now().UnixNano()-t))
			res <- struct{}{}
		}
	}()
	for i := 0; i < 2000; i++ {
		time.Sleep(200 * time.Microsecond) // let the consumer park
		c <- time.Now().UnixNano()
		<-res
	}
	close(c)
	sort.Float64s(lat)
	fmt.Printf("RESULT wake_latency_p50 %.0f\n", lat[len(lat)/2])
	fmt.Printf("RESULT wake_latency_p99 %.0f\n", lat[len(lat)*99/100])
}

func min(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
