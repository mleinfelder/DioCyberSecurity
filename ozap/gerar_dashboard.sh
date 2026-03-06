#!/bin/bash
REPORT_DIR="/scripts"
OUTPUT="index.html"

echo "<html><head><title>ZAP Dashboard</title><style>body{font-family:sans-serif;} table{border-collapse:collapse;width:100%;} th,td{border:1px solid #ddd;padding:8px;} tr:nth-child(even){background-color:#f2f2f2;}</style></head><body>" > "$OUTPUT"
echo "<h1>🛡️ OWASP ZAP Dashboard</h1>" >> "$OUTPUT"
echo "<table><tr><th>Arquivo</th><th>Data</th><th>Tamanho</th></tr>" >> "$OUTPUT"

for file in $(ls -t "$REPORT_DIR"/*.html 2>/dev/null | head -20); do
    filename=$(basename "$file")
    filesize=$(du -h "$file" | cut -f1)
    filedate=$(date -r "$file" '+%Y-%m-%d %H:%M')
    echo "<tr><td><a href='$file'>$filename</a></td><td>$filedate</td><td>$filesize</td></tr>" >> "$OUTPUT"
done

echo "</table></body></html>" >> "$OUTPUT"
echo "Dashboard gerado: $OUTPUT"
