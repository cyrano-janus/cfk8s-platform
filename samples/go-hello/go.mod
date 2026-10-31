module go-hello

// Diese Zeile steuert das Staging NICHT — gemessen am 2026-10-31.
//
// Naheliegend waere, dass das go-Buildpack sie liest und sich danach richtet.
// Es tut es nicht: `cf push` mit `go 1.26.10` hier installierte
// `go 1.25.12`, die Version, die go_buildpack 1.11.0 mitbringt, und meldete
// dabei keinen Konflikt. Womit eine App gebaut wird, entscheidet also das
// Buildpack, nicht das Repo.
//
// Die Gegenprobe gehoert dazu, sonst waere es eine Vermutung: dieselbe App
// ein zweites Mal gepusht, diesmal wieder mit `go 1.23`, dem vorigen Stand
// dieser Zeile — das Buildpack installierte erneut `go 1.25.12`. Es liest die
// Zeile also nicht, in keiner Richtung.
//
// Fuer die Lueckenlage heisst das: `go-hello` laeuft auf der stdlib von
// 1.25.12, und die fuehrt OSV mit 21 Advisories. Die 72 Advisories, die zu
// `go 1.23` gehoeren, waren nie real — gebaut wurde auch damals schon mit
// dem, was das Buildpack mitbrachte. Wer die 21 schliessen will, hebt das
// Buildpack, nicht diese Datei.
//
// Die Zeile bleibt auf 1.26.10, weil sie als Mindestanforderung weiterhin
// richtig ist und bei einem Bau ausserhalb von CF greift. Sie ist nur kein
// Hebel auf die Plattform. Der Gegensatz dazu ist `db-probe`: dort wird lokal
// gebaut, und dort wirkt sie.
go 1.26.10
