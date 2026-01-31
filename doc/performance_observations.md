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

## Test sets

### Test set 2

Running on greene on the main PostgreSQL cluster

* Non-normalized table: (note GIN index was dropped)
  * Copying into view: 1.95 seconds for 60,000 rows = 30,700 rows/sec
  * Copying into samples table directly: Roughly 0.85 sec for 60,000 rows = 70,588 rows/sec
* Regular table with 1 text column:
  * No indexes: 540ms for 60,000 rows = 111,700 rows/sec 
  * No indexes, with a trigger function that just returns NEW: No real impact on performance compared to previous row
  * Adding index on previous table: 930-990ms for 60,000 rows (table not empty)
  * Using spgist index instead of btree: 708-750ms (table not empty)

So the indexes and the little work the trigger function is doing is making a
big impact on performance, though probably a little outsize by comparison to 
the raw table which is obviously peak speed with max benefit from COPY.

* Normalized table:
  * As created: 13.5 sec
  * Dropped indexes on values table: 100ms faster than as created
  * Drop the FK from normalized_labels(labels_id) to normalized_values(id): 500ms faster than as created
  
So far looks like the main contributing factor is the trigger function .. 
let's see what happens if we cut it down a bit.

* Normalized table:
    * With trigger function that returns before the EXECUTE format(INSERT...) (doesn't write anything): 775ms
    * With trigger function that doesn't call current_setting and returns before the EXECUTE format(INSERT...): 720ms
    * With trigger function w/o current_setting calls and doesn't call prom_labels either: 620ms

So, about the performance of the indexed single-column table. Looks like accessing those GUCs 
kicks in a penalty as well. But taking out the call to prom_labels gives us a pretty chunky win.
That function is converting the labels in the sample text into a jsonb. 

## Index only scan on fetching label ID

Changing the unique constraint on the labels table to an index that includes (id) costs ~300ms
in the 60K row test. Not a win.
