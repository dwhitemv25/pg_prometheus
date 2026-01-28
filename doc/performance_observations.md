# Performance observations

## Test VM

Running as byhve VM on greene:
* FreeBSD 15 amd64
* 4 vCPU x Intel(R) Xeon(R) Gold 5315Y CPU @ 3.20GHz
* 4GB RAM
* ~20GB ZFS untuned over monolithic disk image file on SSD RAID10
* PostgreSQL 18

## Trigger function runtime

Trigger function runtime impacts single-threaded ingestion performance.

Adding the labels manipulation from GUC added about 0.08ms/row, from 0.20ms/row
to 0.28ms/row (~100ms/4860 rows to ~130ms/4860 rows) in the test VM.

## Parallelism

Investigating the above, I stood up an Avalance instance with these parameters:

```
go/bin/avalanche --counter-metric-count=100 --series-interval=0
```

This creates ~60,000 timeseries. Inserting this on the test VM takes around 18 seconds pretty consistently.
There is minimal change if inserting all new timeseries labels (e.g., first run).

I ran 4-way parallel Avalanche ingests with the same input data (no change in series or labels) and
all took around the same time, so for high-volume sample ingest parallelism is a win.

One quirk for this is that running that 4-way parallel Avalanche ingest with new labels will block
3 of the threads until the first one finishes,
probably due to the incoming labels being locked while the full transaction completes.
Not sure if big ingests with large volumes of new labels are issues in the real world.
