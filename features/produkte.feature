# language: de

Funktionalität: Produkte

  Grundlage: Produkte existieren
    Angenommen there are the following suppliers:
    |name|
    |Alltron AG|
    Angenommen the following products exist(table):
    |name                         |category     |supplier  |purchase_price|available|visible   |
    |Debian GNU/Linux USB-Stick   |Alle Produkte|Alltron AG|100.0         |yes      |yes       |
    |jET-Notebook XYZ             |Alle Produkte|Alltron AG|100.0         |yes      |yes       |
    |Gartentisch Ikea Surströmming|Alle Produkte|Alltron AG|100.0         |yes      |no        |

  Szenario: Nur diejenigen Produkte anzeigen, die als visible markiert sind
    Wenn ich mir die erste Seite der Gesamt-Produktliste anschaue
    Dann sehe ich das Produkt "Debian GNU/Linux USB-Stick"
    Dann sehe ich das Produkt "jET-Notebook XYZ"
    Dann sehe ich das Produkt "Gartentisch Ikea Surströmming" nicht