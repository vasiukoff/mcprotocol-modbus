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

---

# Шлюз MC Protocol (RS-232) - Modbus RTU over TCP

Данное решение позволяет организовать взаимодействие с ПЛК FX1, FX2, FX3 (включая китайские клоны), подключенными через RS-232 к компьютеру, по сети по следующей схеме:

```
Хост ---(Modbus RTU over TCP)---> Компьютер ---(RS-232 кабель)---> ПЛК
```

Приложение работает как простой шлюз-сервер. Оно ожидает данные по Modbus через TCP, затем запрашивает ПЛК по MC Protocol и возвращает результаты обратно клиенту.

Это позволяет получать данные из различных областей памяти ПЛК (D, C, T, Y, M) по сети. В настоящее время поддерживается только **функция Modbus 03 (чтение регистров хранения)**.

Решение разработано для работы как в Windows, так и в Linux. Предварительно собранные бинарные файлы будут доступны в будущем.

## Чтение данных из ПЛК

Для чтения данных из ПЛК необходимо знать адрес Modbus, соответствующий области памяти ПЛК. Например:

- **D0** соответствует адресу `1000h`
- **D1** соответствует адресу `1002h`  
- **Y0-Y15** соответствует адресу `00A0h`

Для получения полной информации о соответствии адресов обратитесь к таблицам в приложенном файле `mc-protocol.pdf`.
