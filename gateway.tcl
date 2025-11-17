#!/usr/bin/env tclsh

# Функция для чтения конфигурации
proc read_config {file} {
	global config
	set config(tcp_port) 502
	set config(serial_port) COM3
	set config(baud) 38400
	set config(parity) e
	set config(databits) 7
	set config(stopbits) 1
	
    if {[file exists $file]} {
        set fd [open $file r]
        while {[gets $fd line] >= 0} {
            if {[regexp {^(\w+)=(.+)$} $line - key val]} {
                set config($key) $val
            }
        }
        close $fd
    }
}



# Вычисление checksum melsec. Понадобится но наверное потом, если сделаем не только чтение но и запись по modbus.
proc fx_checksum {data} {

}

# Вычисление checksum modbus
proc mb_checksum {data} {

}


# Отправка FX запроса и чтение ответа
proc fx_read {serial data} {

if 0 {
функция на tcl, которая будет преобразовывать и передавать в плк данные. все манипуляции идут с бинарными данными.
в примере данные представлены в hex для удобства.
Пример входного пакета modbus tcp.
01 03 00 A0 00 01 84 28
Два байта первых отсекаем - адрес устройства и номер функции. адрес 01 нам пофиг, номер функции всегда 03. поэтому пока тоже пофиг. но можно сделать проверку чтобы в будущем можно было писать (функция 06).
Берем значение Adr=0x00A0
Берем значение Len=0x0001
Далее 
отсекаем старший байт Len -> Len=0x01
умножаем Len на 2 -> Len = 0x02. умножать нужно потому что melsec оперирует данными длиной 8 бит, а мы запрашиваем данные длиной 16 бит.

Из полученных Adr и Len формируем пакет данных на выходе

02 30 30 30 41 30 30 32 03 36 36 Где
02 30 - константа. по протоколу melsec это команда "считать данные"
30 30 41 30 - значение adr (00A0)  в формате ascii hex
30 32 - значение len (02) в формате ascii hex
03 - константа. по протоколу melsec это признак конца данных.
36 36 - контрольная сумма по мобудлю 256 после 02 и до 03 включительно.
для данного примера значение 36 36 (0x66) - верное.

Далее мы отправляем бинарные данные 02 30 30 30 41 30 30 32 03 36 36 в порт $::serial, и получаем оттуда ответ.

Ответ будет в формате 

02 <данные> 03 CRC1 CRC2
Мы берем данные из ответа и возвращаем их
}

}

proc mb_push {chan data} {

if 0 {

Здесь мы берем данные от ПЛК и формируем Modbus пакет в формате

01 03 <длина в байтах, 1 байт> <данные> <результат mb_checksum, 2 байта.> 

пинаем его в $chan и выходим
}
}

# Обработчик Modbus TCP соединения
proc handle_client {chan addr port} {

    fconfigure $chan -buffering none -encoding binary -translation binary
    while {1} {
        # Чтение команды 03 modbus (8 bytes)
        set data [read $chan 8]
		set response [ fx_read $data ]
		mb_push $chan $response

}

# Основной код
read_config "gateway.conf"
set ::serial [open $config(serial_port) r+]
fconfigure $::serial -mode "$config(baud),$config(parity),$config(databits),$config(stopbits)" -buffering none -encoding binary -translation binary -blocking 0

# Запуск TCP сервера
socket -server handle_client $config(tcp_port)

# Бесконечный цикл для работы как служба
vwait forever