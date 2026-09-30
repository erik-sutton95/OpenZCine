---
title: PTP-IP packet
description: CIPA DC-005 packet framing, packet types, and the PTP operation, response and event layouts carried inside.
---

Framing is in `Sources/OpenZCineCore/PTPIPPacket.swift` (self-tested). All
integers are **little-endian**. Plaintext, no encryption on the link.

## Layout

```text
length:u32le | type:u32le | payload
```

| Field | Notes |
| --- | --- |
| length | Whole packet, header included. Less than 8 is invalid. |
| type | Packet type, below |
| payload | Type-specific |

## Packet types

| Value | Type | Channel | Notes |
| --- | --- | --- | --- |
| `1` | Init_Command_Request | command | 16-byte initiator GUID, UTF-16LE friendly name with NUL, protocol version `0x00010000` |
| `2` | Init_Command_Ack | command | Connection number `u32`, then the camera's name |
| `3` | Init_Event_Request | event | The connection number from the ack |
| `4` | Init_Event_Ack | event | Header only |
| `5` | Init_Fail | either | Reason: `1` rejected initiator, `2` busy, `3` unspecified |
| `6` | Operation_Request | command | See below |
| `7` | Operation_Response | command | See below |
| `8` | Event | event | See below |
| `9` | Start_Data | command | Transaction ID and total length of the data phase |
| `0x0A` | Data | command | Transaction ID `u32`, then a chunk |
| `0x0B` | Cancel | command | |
| `0x0C` | End_Data | command | Transaction ID `u32`, then the last chunk |
| `0x0D` / `0x0E` | Probe_Request / Probe_Response | event | Header-only liveness ping. Answer it: a missing response lets the camera treat the host as dead and close the session. |

## Operation request

```text
dataPhase:u32le | opcode:u16le | transactionID:u32le | params:u32le × 0…5
```

| dataPhase | Meaning |
| --- | --- |
| `1` | No data phase, or data-in as accepted by the ZR |
| `2` | Data-out (host to camera) |
| `3` | Data-in (camera to host), the canonical value |

`OpenSession` uses transaction ID 0. After that the transport assigns
sequential IDs.

## Operation response and event

```text
code:u16le | transactionID:u32le | params:u32le × n
```

The same shape serves `Operation_Response` (a response code such as `0x2001`
OK) and `Event` (an event code such as `0x4006` DevicePropChanged). See the
[command catalog](../commands/).

## Data phase

A data-in transaction arrives as `Start_Data`, zero or more `Data`, then
`End_Data`, then `Operation_Response`. The collector strips the 4-byte
transaction ID from each chunk and concatenates the rest. Real Nikon
transactions are four packets or fewer; large objects are read in bounded
[partial reads](../media/).

## USB container

Over USB-C the same operations ride PIMA 15740 generic containers instead
(`PTPUSBContainer.swift`):

```text
length:u32le | type:u16le | code:u16le | transactionID:u32le | payload
```

| Type | Meaning |
| --- | --- |
| `1` | Command |
| `2` | Data |
| `3` | Response |
| `4` | Event |

The USB command container has **no DataPhaseInfo field**, and the operation,
response or event code sits in the container header. One bulk read can carry
part of a container or several containers, so a framing buffer vends exactly
one validated container at a time. See [transport](../ptpip-transport/).
