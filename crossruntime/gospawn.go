package main

import (
	"fmt"
	"runtime"
	"sync"
	"time"
)

const PER = 25000
const TOTAL = 2000000

func wave(per int) {
	var wg sync.WaitGroup
	wg.Add(per)
	for i := 0; i < per; i++ {
		go func() { wg.Done() }()
	}
	wg.Wait()
}

func produce(waves int) {
	for i := 0; i < waves; i++ {
		wave(PER)
	}
}

func runProducers(p int) float64 {
	waves := TOTAL / (p * PER)
	start := time.Now()
	var wg sync.WaitGroup
	wg.Add(p)
	for i := 0; i < p; i++ {
		go func() { defer wg.Done(); produce(waves) }()
	}
	wg.Wait()
	return float64(TOTAL) / time.Since(start).Seconds() / 1e6
}

func main() {
	fmt.Printf("# GOMAXPROCS=%d\n", runtime.GOMAXPROCS(0))
	produce(4) // warmup
	start := time.Now()
	produce(TOTAL / PER)
	fmt.Printf("RESULT main_producer %6.2f Mtask/s\n", float64(TOTAL)/time.Since(start).Seconds()/1e6)
	for _, p := range []int{1, 2, 4, 8} {
		fmt.Printf("RESULT pool_prod_P%d  %6.2f Mtask/s\n", p, runProducers(p))
	}
}
