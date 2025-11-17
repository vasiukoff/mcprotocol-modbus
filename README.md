# MC Protocol (RS-232) to Modbus RTU over TCP Gateway

This solution enables communication with FX1, FX2, and FX3 PLCs (including Chinese clones) connected via RS-232 to a computer, allowing access over a network using the following scheme:

```
Host ---(Modbus RTU over TCP)---> Computer ---(RS-232 Cable)---> PLC
```

The application functions as a simple gateway server. It listens for Modbus requests over TCP, queries the PLC using the MC Protocol, and returns the results back to the client.

This gateway allows reading data from various PLC memory areas (D, C, T, Y, M) over the network. Currently, only **Modbus function code 03 (Read Holding Registers)** is supported.

The solution is designed to work on both Windows and Linux operating systems. Pre-built binaries will be made available in the future.

## Reading Data from the PLC

To read data from the PLC, you need to know the Modbus address corresponding to the PLC memory location. For example:

- **D0** corresponds to address `1000h`
- **D1** corresponds to address `1002h`
- **Y0-Y15** corresponds to address `00A0h`

Please refer to the address tables in the attached `mc-protocol.pdf` file for complete address mapping information.
