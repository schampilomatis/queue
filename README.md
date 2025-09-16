### Data

<topic>
    <partition>/
        - .meta
        - 0001
        - 0001.meta
        - 0002
        - 0002.meta




### Threads

## Reader

On Startup, get a range of partitions. For this example lets say only 1.
Read the metadata, check latest offset and emit that value
Incoming data go to reader memory until some limit and also written to disk
If a subscriber exists push data directly from memory and advance the offset


## Deleter

scan partition files for things that have finished consuming and delete them.
