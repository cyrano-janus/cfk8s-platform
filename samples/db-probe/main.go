// Die Probe zu FINDINGS #32: kommt eine CF-Anwendung an den Dienst, den der
// Broker ihr gebunden hat?
//
// Sie spricht absichtlich KEIN Postgres. Gefragt ist der Netzweg, und den
// beantwortet ein TCP-Verbindungsversuch vollstaendig: kommt die Verbindung
// zustande, hat die Plattform sie erlaubt. Ein echter Treiber braeuchte eine
// Abhaengigkeit, die beim Staging geladen wird, und verwechselte am Ende
// Anmeldefehler mit Netzsperren.
//
// Auflösung und Verbindung werden GETRENNT gemeldet. Beide koennen scheitern,
// und sie bedeuten Verschiedenes: ein unaufloesbarer Name ist ein Befund ueber
// die Zugangsdaten des Brokers (#5), eine stumme Verbindung einer ueber die
// Netzregeln der Plattform (#32). Wer nur "geht nicht" misst, verwechselt sie.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Die Frist ist kurz und gehoert in die Messung selbst. Eine gesperrte
// Verbindung antwortet nicht - sie schweigt, bis das Betriebssystem aufgibt,
// und das sind Minuten. Wer ohne Frist misst, misst die Geduld des Kernels.
const frist = 5 * time.Second

type ziel struct {
	Dienst string `json:"dienst"`
	Quelle string `json:"quelle"` // welches Feld der Credentials die Adresse lieferte
	Host   string `json:"host"`
	Port   string `json:"port"`
}

type befund struct {
	ziel
	Aufgeloest bool     `json:"aufgeloest"`
	Adressen   []string `json:"adressen,omitempty"`
	Erreichbar bool     `json:"erreichbar"`
	Dauer      string   `json:"dauer"`
	Fehler     string   `json:"fehler,omitempty"`
}

// Der Broker liefert den Port mal als Zahl, mal als Zeichenkette. Beides ist
// gueltiges JSON, und ein Typ, der nur eines kennt, laesst die Probe still
// leerlaufen - gemessen am 2026-09-23: "port": "5432".
type zahlOderText string

func (z *zahlOderText) UnmarshalJSON(b []byte) error {
	*z = zahlOderText(strings.Trim(string(b), `"`))
	return nil
}

type bindung struct {
	Name        string `json:"name"`
	Credentials struct {
		Host    string       `json:"host"`
		Port    zahlOderText `json:"port"`
		FqdnURI string       `json:"fqdn-uri"`
		URI     string       `json:"uri"`
	} `json:"credentials"`
}

// Bevorzugt wird der vollstaendige Name aus fqdn-uri. Das Feld `host` traegt
// auf dieser Plattform den Kurznamen des Service-Objekts ohne Namespace; aus
// einem CF-Container ist er nicht aufloesbar, und eine Probe, die daran
// scheitert, misst die Namensaufloesung statt der Netzregel.
func adresse(b bindung) (host, port, quelle string) {
	for _, kandidat := range []struct{ feld, roh string }{
		{"fqdn-uri", b.Credentials.FqdnURI},
		{"uri", b.Credentials.URI},
	} {
		if kandidat.roh == "" {
			continue
		}
		u, err := url.Parse(kandidat.roh)
		if err != nil || u.Hostname() == "" {
			continue
		}
		return u.Hostname(), u.Port(), kandidat.feld
	}
	return b.Credentials.Host, string(b.Credentials.Port), "host/port"
}

// VCAP_SERVICES ist nach Diensttyp gruppiert; jede Gruppe ist eine Liste von
// Bindungen. Welche Typen es gibt, weiss die Anwendung nicht - deshalb ueber
// alle laufen statt einen Namen zu raten.
func ziele() []ziel {
	roh := os.Getenv("VCAP_SERVICES")
	if roh == "" {
		return nil
	}
	var gruppen map[string][]bindung
	if err := json.Unmarshal([]byte(roh), &gruppen); err != nil {
		log.Printf("PROBE VCAP_SERVICES nicht lesbar: %v", err)
		return nil
	}
	var out []ziel
	for _, bindungen := range gruppen {
		for _, b := range bindungen {
			host, port, quelle := adresse(b)
			if host == "" || port == "" {
				log.Printf("PROBE Bindung %q ohne brauchbare Adresse", b.Name)
				continue
			}
			out = append(out, ziel{Dienst: b.Name, Quelle: quelle, Host: host, Port: port})
		}
	}
	return out
}

func pruefe(z ziel) befund {
	b := befund{ziel: z}
	start := time.Now()

	if adr, err := net.LookupHost(z.Host); err == nil {
		b.Aufgeloest, b.Adressen = true, adr
	} else {
		b.Fehler = "Namensaufloesung: " + err.Error()
		b.Dauer = time.Since(start).Round(time.Millisecond).String()
		return b
	}

	c, err := net.DialTimeout("tcp", net.JoinHostPort(z.Host, z.Port), frist)
	b.Dauer = time.Since(start).Round(time.Millisecond).String()
	if err != nil {
		b.Fehler = "Verbindung: " + err.Error()
		return b
	}
	c.Close()
	b.Erreichbar = true
	return b
}

func alleBefunde() []befund {
	zs := ziele()
	out := make([]befund, 0, len(zs))
	for _, z := range zs {
		out = append(out, pruefe(z))
	}
	return out
}

func main() {
	// Erst messen, dann lauschen, und das Ergebnis ins Log: eine Anwendung,
	// die ihren Dienst nicht erreicht, ist auf einer abgeschotteten Plattform
	// oft auch von aussen nicht erreichbar. Was im Log steht, holt `cf logs`
	// trotzdem heraus.
	for _, b := range alleBefunde() {
		roh, _ := json.Marshal(b)
		log.Printf("PROBE %s", roh)
	}

	mux := http.NewServeMux()
	// Der Health Check darf NICHT von der Messung abhaengen. Sonst stirbt die
	// Anwendung an einem gesperrten Netzweg, und die Plattform meldet einen
	// Startabbruch statt eines Messwertes - genau die Verwechslung, die den
	// Befund #32 lange verdeckt hat.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(alleBefunde())
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
