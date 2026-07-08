use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::sync::Notify;

const PER: usize = 25_000;
const TOTAL: usize = 2_000_000;

// WaitGroup-shaped join: counter + notify, so we don't pay 25k JoinHandle
// registrations per wave (closer to Julia's @sync / Go's WaitGroup).
async fn wave(per: usize) {
    let n = Arc::new(AtomicUsize::new(per));
    let notify = Arc::new(Notify::new());
    for _ in 0..per {
        let n = n.clone();
        let notify = notify.clone();
        tokio::spawn(async move {
            if n.fetch_sub(1, Ordering::AcqRel) == 1 {
                notify.notify_one();
            }
        });
    }
    while n.load(Ordering::Acquire) != 0 {
        notify.notified().await;
    }
}

async fn produce(waves: usize) {
    for _ in 0..waves {
        wave(PER).await;
    }
}

fn main() {
    let threads: usize = std::env::var("TOKIO_WORKERS")
        .map(|s| s.parse().unwrap())
        .unwrap_or(8);
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(threads)
        .build()
        .unwrap();
    println!("# tokio worker_threads={}", threads);
    rt.block_on(async {
        produce(4).await; // warmup
        // block_on runs on a non-worker thread: every spawn is a remote
        // (inject-queue) spawn, like Julia's interactive-thread main task.
        let t0 = std::time::Instant::now();
        produce(TOTAL / PER).await;
        println!(
            "RESULT main_producer {:6.2} Mtask/s",
            TOTAL as f64 / t0.elapsed().as_secs_f64() / 1e6
        );
        for p in [1usize, 2, 4, 8] {
            let waves = TOTAL / (p * PER);
            let t0 = std::time::Instant::now();
            let hs: Vec<_> = (0..p).map(|_| tokio::spawn(produce(waves))).collect();
            for h in hs {
                h.await.unwrap();
            }
            println!(
                "RESULT pool_prod_P{} {:6.2} Mtask/s",
                p,
                TOTAL as f64 / t0.elapsed().as_secs_f64() / 1e6
            );
        }
    });
}
