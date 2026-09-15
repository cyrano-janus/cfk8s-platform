package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"message":               "Hallo von Go auf Korifi",
			"buildpack":             "paketo-buildpacks/go",
			"vcap_services_present": os.Getenv("VCAP_SERVICES") != "",
		})
	})
	http.HandleFunc("/env", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"vcap_services": os.Getenv("VCAP_SERVICES")})
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// Ein je Start neu gezogener Schluessel, und er steht AUSSCHLIESSLICH in
	// dieser einen Logzeile.
	//
	// Nicht im Antwortkoerper, nicht unter /env, nirgends abrufbar: wer ihn
	// haben will, muss den Logstrom offen haben, waehrend die Instanz
	// hochkommt. Das ist der Grund, warum es ihn gibt - Kapitel 2 des
	// Lernspiels (../../../cf-lernspiel) haengt daran, dass eine Groesse nur
	// beim Start genannt wird und nachtraeglich nicht mehr zu holen ist. Wer
	// ihn hier in eine Antwort aufnimmt, nimmt dem Kapitel seinen Gegenstand.
	//
	// Nebenbei macht er im Strom unterscheidbar, welcher Start gerade spricht.
	roh := make([]byte, 4)
	if _, err := rand.Read(roh); err != nil {
		log.Fatal(err)
	}
	log.Printf("store key %s", hex.EncodeToString(roh))

	log.Printf("listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
