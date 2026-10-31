module db-probe

// Nicht die Sprachversion, sondern die Mindest-Toolchain — und hier wiegt sie
// schwerer als anderswo: die Probe wird LOKAL gebaut und als fertiges Programm
// mit dem binary_buildpack gepusht (manifest.yml). Was die Toolchain an
// Standardbibliothek einbackt, laeuft genau so im Cluster; kein Buildpack
// baut das spaeter neu.
//
// Unter 1.26.10 traegt die Standardbibliothek Luecken, die OSV fuer die
// jeweilige Version fuehrt - fuer das zuvor hier gebaute go1.22.2 sind es 76.
// Ab 1.26.10 sind es null. GOTOOLCHAIN=auto laedt die Toolchain anhand dieser
// Zeile nach, ein lokal installiertes aelteres Go genuegt also nicht mehr
// stillschweigend.
go 1.26.10
