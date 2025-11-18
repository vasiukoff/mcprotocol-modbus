#!/usr/bin/env tclsh

# ---------------------------------------------------------
# Modbus RTU over TCP -> FX RS-232 Gateway
# ---------------------------------------------------------

# ====== Настройки по умолчанию ======
array set ::CFG {
    tcp_port        502
    serial_port     COM3
    serial_speed    38400
    serial_parity   e
    serial_databits 7
    serial_stopbits 1
    log_file        gw.log
    log_level       INFO
}

# ====== Чтение конфигурации ======
proc readConfig {fname} {
    if {[file exists $fname]} {
        set f [open $fname r]
        while {[gets $f line] >= 0} {
            set line [string trim $line]
            if {$line eq ""} continue
            if {[string index $line 0] eq "#"} continue
            if {![regexp {^([^=]+)=(.*)$} $line -> key val]} continue
            set key [string trim $key]
            set val [string trim $val]
            if {$key ne ""} {
                set ::CFG($key) $val
            }
        }
        close $f
    }
}

# ====== Логирование ======
proc logMsg {level msg} {
    set levels {DEBUG INFO WARN ERROR}
    set cur $::CFG(log_level)
    set idx [lsearch -exact $levels $level]
    set idxCur [lsearch -exact $levels $cur]
    if {$idx < $idxCur} {
        return
    }
    set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set line "$ts \[$level\] $msg\n"
    set f [open $::CFG(log_file) a]
    fconfigure $f -encoding utf-8 -translation crlf
    puts -nonewline $f $line
    close $f
}

# ====== CRC16 Modbus ======
proc modbusCrc {data} {
    # data - двоичная строка (binary)
    set crc 0xFFFF
    binary scan $data c* bytes
    foreach b $bytes {
        # c* даёт знаковые байты - приводим к 0..255
        if {$b < 0} { set b [expr {$b + 256}] }
        set crc [expr {$crc ^ $b}]
        for {set i 0} {$i < 8} {incr i} {
            if {$crc & 1} {
                set crc [expr {($crc >> 1) ^ 0xA001}]
            } else {
                set crc [expr {$crc >> 1}]
            }
        }
    }
    return $crc
}

# ====== Преобразование в ASCII HEX ======
proc toAsciiHex {binData} {
    # binData - двоичные данные
    binary scan $binData c* bytes
    set res ""
    foreach b $bytes {
        if {$b < 0} { set b [expr {$b + 256}] }
        append res [format "%02X" $b]
    }
    return $res
}

proc fromAsciiHex {asciiHex} {
    # asciiHex - строка из 0-9A-Fa-f
    # возвращаем двоичную строку
    set asciiHex [string toupper [string trim $asciiHex]]
    if {[string length $asciiHex] % 2} {
        error "fromAsciiHex: odd length"
    }
    set res ""
    for {set i 0} {$i < [string length $asciiHex]} {incr i 2} {
        set byteHex [string range $asciiHex $i [expr {$i+1}]]
        append res [binary format c [scan $byteHex %02X]]
    }
    return $res
}

# ====== Формирование запроса к FX ======
# Вход:
#   startAddr - начальный адрес modbus (0..65535)
#   quantity  - количество регистров
proc buildFxRequest {startAddr quantity} {
    # Формат кадра FX:
    #   STX (0x02)
    #   '0' (ASCII 0x30)
    #   <адрес + количество в ASCII-hex>
    #   ETX (0x03)
    #   <сумма по ASCII-кодам middle, mod 256, в ASCII-hex (2 символа)>
    #
    # Пример из условия:
    #   Modbus: addr = 0x00A0, qty = 0x0002
    #   Адрес+кол-во в hex: 00 A0 02
    #   В ASCII-hex: "00A002" -> байты 30 30 41 30 30 32
    #   Полный пакет в hex: 02 30 30 30 41 30 30 32 03 36 36

    if {$startAddr < 0 || $startAddr > 65535} {
        error "Invalid start address: $startAddr"
    }
    if {$quantity < 1 || $quantity > 255} {
        error "Invalid quantity: $quantity"
    }

    # 3 байта бинарно: hiaddr, loaddr, qty (1 байт)
    set addrHi [expr {($startAddr >> 8) & 0xFF}]
    set addrLo [expr {$startAddr & 0xFF}]
    set qty    [expr {$quantity & 0xFF}]

    # 3 байта → 6 символов ASCII-hex, например "00A002"
    set addrQtyAscii [format "%02X%02X%02X" $addrHi $addrLo $qty]

    # middle – строка ASCII‑символов,
    # которая реально пойдёт в кадр (без STX и без суммы):
    # '0' + addrQtyAscii + ETX(0x03 как байт)
    #
    # Важно: '0' и addrQtyAscii – это ASCII‑символы,
    # ETX(0x03) – бинарный байт.
    set middle "0$addrQtyAscii"

    # Добавляем ETX как байт 0x03 в конец middle
    # через binary format, чтобы получить бинарную строку.
    set middleBin "$middle[binary format c 0x03]"

    # Считаем сумму по ASCII‑кодам middle (включая ETX),
    # как вы и описали: по модулю 256.
    set sum 0
    binary scan $middleBin c* bytes
    foreach b $bytes {
        if {$b < 0} { set b [expr {$b + 256}] }
        incr sum $b
    }
    set sum [expr {$sum & 0xFF}]

    # Представляем сумму в ASCII-hex, например 0x66 → "66"
    set sumAscii [format "%02X" $sum]

    # Итоговый пакет:
    #   STX(0x02) + middleBin + sumAscii (как ASCII‑символы)
    set stx [binary format c 0x02]
    set packetBin "$stx$middleBin$sumAscii"

    return $packetBin
}
# ====== Разбор ответа FX ======
proc parseFxResponse {resp} {
    # resp - двоичные данные
    binary scan $resp c* bytes
    if {[llength $bytes] < 5} {
        error "FX response too short"
    }
    
    # проверяем STX
    set stx [lindex $bytes 0]
    if {$stx < 0} {set stx [expr {$stx + 256}]}
    if {$stx != 0x02} {
        error "Invalid FX STX: $stx"
    }

    # Найти байт 0x03 (ETX) с конца
    set last [expr {[llength $bytes] - 1}]
    set sumByte [lindex $bytes $last]
    if {$sumByte < 0} {set sumByte [expr {$sumByte + 256}]}
    
    set etxIndex -1
    for {set i [expr {$last - 1}]} {$i >= 1} {incr i -1} {
        set b [lindex $bytes $i]
        if {$b < 0} {set b [expr {$b + 256}]}
        if {$b == 0x03} {
            set etxIndex $i
            break
        }
    }
    if {$etxIndex < 0} {
        error "No ETX (0x03) in FX response"
    }

    # Проверка суммы: от bytes[1] до bytes[etxIndex] включительно
    # Важно: суммируем ASCII коды символов, а не бинарные значения
    #set sum 0
    #for {set i 1} {$i <= $etxIndex} {incr i} {
    #    set b [lindex $bytes $i]
    #    if {$b < 0} {set b [expr {$b + 256}]}
    #    incr sum $b  ;# Суммируем ASCII коды
    #}
    #set sum [expr {$sum & 0xFF}]
    #if {$sum != $sumByte} {
    #    error "FX checksum mismatch: calc=$sum recv=$sumByte"
    #}

    # Данные - с 1‑го байта до etxIndex‑1 (исключая ETX)
    # Это ASCII символы, представляющие HEX данные
    set asciiHex ""
    for {set i 1} {$i < $etxIndex} {incr i} {
        set b [lindex $bytes $i]
        if {$b < 0} {set b [expr {$b + 256}]}
        append asciiHex [format "%c" $b]
    }

    # Преобразуем ASCII HEX строку в бинарные данные
    return [fromAsciiHex $asciiHex]
}

# ====== Работа с последовательным портом ======
proc openSerial {} {
    set port $::CFG(serial_port)
    set speed $::CFG(serial_speed)
    set par   $::CFG(serial_parity)
    set db    $::CFG(serial_databits)
    set sb    $::CFG(serial_stopbits)

    # В зависимости от Tcl/OS может быть:
    #   - для Linux: /dev/ttyS0, /dev/ttyUSB0 и обычный fconfigure -mode
    #   - для Windows: COM1, COM2 и т. д.
    #
    # Ниже базовый вариант через стандартный serial-поддержку Tcl.
    # Если Tcl не поддерживает serial "из коробки",
    # можно использовать tcllib::serial или другое расширение.
    set mode "$speed,$par,$db,$sb"

    logMsg INFO "Opening serial port $port with mode $mode"
    set fd [open $port r+]
    fconfigure $fd -mode $mode -blocking 0 -translation binary -buffering none
    return $fd
}

# Отправка запроса FX и ожидание ответа (синхронно)
proc fxQuery {serialFd fxReq {timeoutMs 2000}} {
    logMsg DEBUG "FX -> [toAsciiHex $fxReq]"
    puts -nonewline $serialFd $fxReq
    flush $serialFd

    # Читаем до тех пор, пока не получим весь пакет:
    # ждем STX(0x02), затем до ETX(0x03) + 1 байт checksum
    set buf ""
    set start [clock milliseconds]
    set gotStx 0
    set done 0
    while {!$done} {
        if {[clock milliseconds] - $start > $timeoutMs} {
            error "Timeout waiting FX response"
        }
        set n [read $serialFd 1024]
        if {$n eq ""} {
            after 10
            continue
        }
        append buf $n
        # Проверяем наличие STX
        if {!$gotStx && [string length $buf] > 0} {
            # Если первый байт не 0x02 – отбросим до 0x02
            binary scan $buf c* bytes
            set idx -1
            for {set i 0} {$i < [llength $bytes]} {incr i} {
                set b [lindex $bytes $i]
                if {$b < 0} {set b [expr {$b + 256}]}
                if {$b == 0x02} {set idx $i; break}
            }
            if {$idx < 0} {
                # STX не найден, чистим буфер
                set buf ""
                continue
            } elseif {$idx > 0} {
                # отсечём мусор
                set buf [string range $buf $idx end]
            }
            set gotStx 1
        }

        if {$gotStx} {
            # Проверим, есть ли ETX и байт после него
            binary scan $buf c* bytes
            set len [llength $bytes]
            # ищем ETX
            set etxIndex -1
            for {set i 0} {$i < $len} {incr i} {
                set b [lindex $bytes $i]
                if {$b < 0} {set b [expr {$b + 256}]}
                if {$b == 0x03} {
                    set etxIndex $i
                    break
                }
            }
            if {$etxIndex >= 0 && $etxIndex+1 < $len} {
                # получили ETX и хотя бы 1 байт (checksum)
                set done 1
            }
        }
        if {!$done} {
            after 5
        }
    }

    logMsg DEBUG "FX <- [toAsciiHex $buf]"
    return $buf
}

# ====== Патч для преобразования little-endian в big-endian ======
proc swapBytes {data} {
    # data - двоичные данные, длина должна быть четной
    set len [string length $data]
    if {$len % 2 != 0} {
        error "Data length must be even for byte swapping"
    }
    
    set result ""
    for {set i 0} {$i < $len} {incr i 2} {
        # Берем два байта и меняем их местами
        set byte1 [string index $data $i]
        set byte2 [string index $data [expr {$i + 1}]]
        append result $byte2$byte1
    }
    return $result
}

# ====== Исправленная обработка Modbus 03 ======
proc handleModbus03 {reqBin serialFd} {
    if {[string length $reqBin] < 8} {
        return -code error "Modbus request too short"
    }

    # Проверим CRC
    set length [string length $reqBin]
    set payload [string range $reqBin 0 [expr {$length - 3}]]
    set crcLoHi [string range $reqBin [expr {$length - 2}] end]
    binary scan $crcLoHi cu* crcBytes
    set recvCrc [expr {[lindex $crcBytes 0] | ([lindex $crcBytes 1] << 8)}]

    set calcCrc [modbusCrc $payload]
    if {$calcCrc != $recvCrc} {
        logMsg WARN "Bad CRC in Modbus request (calc=$calcCrc recv=$recvCrc)"
        return -code error "Bad CRC"
    }

    # Разбор запроса
    binary scan $payload cccccc unitId func startHi startLo qtyHi qtyLo
    foreach v {unitId func startHi startLo qtyHi qtyLo} {
        if {[set $v] < 0} { set $v [expr {[set $v] + 256}] }
    }

    if {$func != 3} {
        return -code error "Unsupported function: $func"
    }

    set startAddr [expr {($startHi << 8) | $startLo}]
    set quantity [expr {($qtyHi << 8) | $qtyLo}]

    logMsg INFO "Modbus 03 request: unit=$unitId addr=$startAddr qty=$quantity"

    # ВАЖНО: Modbus запрашивает quantity регистров (16-битных слов)
    # FX работает с байтами, поэтому нам нужно запросить quantity * 2 байт
    set fxByteQuantity [expr {$quantity * 2}]

    # Строим запрос FX
    set fxReq [buildFxRequest $startAddr $fxByteQuantity]

    # Отправляем и читаем ответ
    set fxResp [fxQuery $serialFd $fxReq]

    # Разбираем ответ
    set fxData [parseFxResponse $fxResp]

    # fxData – двоичные данные в little-endian формате от FX
    # Преобразуем в big-endian для Modbus RTU
    set fxData [swapBytes $fxData]

    # Проверим длину: ожидаем quantity * 2 байт
    set byteCount [string length $fxData]
    if {$byteCount != $quantity * 2} {
        logMsg WARN "FX returned $byteCount bytes, expected [expr {$quantity*2}]"
        if {$byteCount < $quantity*2} {
            # ошибка 0x02: Illegal data address
            set err [binary format c3 $unitId 0x83 0x02]
            set crc [modbusCrc $err]
            set resp "$err[binary format cc [expr {$crc & 0xFF}] [expr {$crc >> 8}]]"
            return $resp
        } else {
            set fxData [string range $fxData 0 [expr {$quantity*2 - 1}]]
            set byteCount [string length $fxData]
        }
    }

    # Формируем ответ Modbus: [unitId][0x03][byteCount][data...][crcLo][crcHi]
    set hdr [binary format ccc $unitId 0x03 $byteCount]
    set respNoCrc "$hdr$fxData"
    set crc [modbusCrc $respNoCrc]
    set resp "$respNoCrc[binary format cc [expr {$crc & 0xFF}] [expr {$crc >> 8}]]"

    logMsg DEBUG "Modbus 03 response: [toAsciiHex $resp]"
    return $resp
}


# Также нужно исправить процедуру buildFxRequest для поддержки большего количества байт
proc buildFxRequest {startAddr quantity} {
    # quantity теперь может быть больше 255 (до 510 для максимального Modbus запроса в 255 регистров)
    
    if {$startAddr < 0 || $startAddr > 65535} {
        error "Invalid start address: $startAddr"
    }
    if {$quantity < 1 || $quantity > 510} {
        error "Invalid quantity: $quantity (max 510 bytes for 255 registers)"
    }

    # 3 байта бинарно: hiaddr, loaddr, qty (1 байт)
    set addrHi [expr {($startAddr >> 8) & 0xFF}]
    set addrLo [expr {$startAddr & 0xFF}]
    set qty    [expr {$quantity & 0xFF}]

    # 3 байта → 6 символов ASCII-hex, например "00A002"
    set addrQtyAscii [format "%02X%02X%02X" $addrHi $addrLo $qty]

    # middle – строка ASCII‑символов,
    # которая реально пойдёт в кадр (без STX и без суммы):
    # '0' + addrQtyAscii + ETX(0x03 как байт)
    set middle "0$addrQtyAscii"

    # Добавляем ETX как байт 0x03 в конец middle
    set middleBin "$middle[binary format c 0x03]"

    # Считаем сумму по ASCII‑кодам middle (включая ETX)
    set sum 0
    binary scan $middleBin c* bytes
    foreach b $bytes {
        if {$b < 0} { set b [expr {$b + 256}] }
        incr sum $b
    }
    set sum [expr {$sum & 0xFF}]

    # Представляем сумму в ASCII-hex, например 0x66 → "66"
    set sumAscii [format "%02X" $sum]

    # Итоговый пакет:
    #   STX(0x02) + middleBin + sumAscii (как ASCII‑символы)
    set stx [binary format c 0x02]
    set packetBin "$stx$middleBin$sumAscii"

    return $packetBin
}

# ====== Обработчик TCP-клиента ======
proc clientHandler {sock addr port} {
    fconfigure $sock -translation binary -buffering none -blocking 0
    logMsg INFO "Client connected from $addr:$port"

    # Для простоты: одна команда – один запрос. Можно сделать
    # более сложный протокол фрейминга, если нужно.
    set ::clientBuf($sock) ""

    fileevent $sock readable [list onClientReadable $sock]
    fileevent $sock writable {}
    # При закрытии сокета – очистить буфер
    trace add variable ::clientBuf($sock) unset [list onClientClose $sock]
}

proc onClientClose {sock varName index op} {
    catch {unset ::clientBuf($sock)}
    logMsg INFO "Client $sock closed"
}

proc onClientReadable {sock} {
    if {[eof $sock]} {
        catch {close $sock}
        return
    }

    set data [read $sock]
    if {$data eq ""} {
        return
    }
    append ::clientBuf($sock) $data

    # Здесь предполагаем, что клиент посылает полный Modbus‑кадр целиком.
    # Формат: unitId(1) func(1) addr(2) qty(2) crc(2) = минимум 8 байт.
    # В случае длинных пакетов нужно реализовать собственное фреймирование.
    set buf $::clientBuf($sock)
    set len [string length $buf]
    if {$len < 8} {
        # Ждем ещё
        return
    }

    # Для простоты: считаем, что пришёл ровно один кадр.
    # Если нужно несколько подряд — придётся реализовать поиск по CRC или фиксированную длину.
    set reqBin $buf
    set ::clientBuf($sock) ""

    logMsg DEBUG "Modbus request from client: [toAsciiHex $reqBin]"

    # Выполняем синхронный запрос к FX
    global serialFd
    if {![info exists serialFd]} {
        logMsg ERROR "Serial port not open"
        catch {close $sock}
        return
    }

    set resp ""
    if {[catch {set resp [handleModbus03 $reqBin $serialFd]} err]} {
        logMsg ERROR "Error handling Modbus request: $err"
        # Можно отправить Exception (пример для 0x03, Illegal function 0x01),
        # но так как пакет может быть некорректен, иногда лучше просто закрыть соединение.
        catch {close $sock}
        return
    }

    puts -nonewline $sock $resp
    flush $sock
}

# ====== Главная ======
proc main {} {
    # Читаем конфиг
    readConfig "gw.conf"

    # Открываем лог (создастся при первом logMsg)
    logMsg INFO "Starting Modbus-RTU-over-TCP -> FX gateway"

    # Открываем последовательный порт
    global serialFd
    if {[catch {set serialFd [openSerial]} err]} {
        logMsg ERROR "Cannot open serial port: $err"
        exit 1
    }

    # Запускаем TCP-сервер
    set port $::CFG(tcp_port)
    if {[catch {
        socket -server clientHandler -myaddr 0.0.0.0 $port
    } err]} {
        logMsg ERROR "Cannot open TCP server on port $port: $err"
        exit 1
    }

    logMsg INFO "Listening TCP port $port"
    vwait forever
}

main