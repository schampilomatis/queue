# Queue

A simple message queue system that provides the following API:
- `GET` - Retrieve messages
- `PUT` - Add messages
- `ACK` - Acknowledge message processing
- `UNACK` - Mark message as unacknowledged (with timeout)

The system allows writing messages on one side and reading them on the other, with goals of persistence, failure recovery, at-least-once delivery, and automatic dead letter queue (DLQ) handling.

## Implementation

All operations are stored in a log-based system with three main threads:

Metadata: 
    - write_file_path
    - write_offset
    - read_file_path
    - read_offset
    - inflight:
        - file_path
        - offset
        - at


### Writer

Adds messages to the latest file and maintains metadata derived from the log. 


### Reader

Reads messages from the current file, tracks acknowledgments and timeouts, moves messages to DLQ after too many timeout failures. When a message isn't acknowledged in time, an unack operation is logged and a copy of the message is created with reduced retry count

### Deleter

Cleans up files once the reader's current index has moved beyond the last processed file




