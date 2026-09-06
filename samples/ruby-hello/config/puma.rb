# Puma lauscht ohne diese Zeile auf seinem eigenen Default (9292) und ist damit
# hinter Korifis Route nicht erreichbar. Der Port kommt aus PORT, das der
# AppWorkload setzt.
port ENV.fetch("PORT") { 8080 }
