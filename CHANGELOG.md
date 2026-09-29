# Cambios

## 2.0 — 2026-09-29
- **Tabla final** (`resumen`): al terminar un reparto, qué se mandó a cada motor, cuánto tardó y cómo salió la revisión. El registro guarda objetivo, ficheros y tiempo.
- **Veredicto `nulo`** (el motor no llegó a trabajar: sin cuenta en la regla de las 3) y `limpiar --forzar`.
- Reactivar un motor reinicia la cuenta de la regla de las 3.
- **Seguridad:** GLM con `HOME` desechable, sin `python3`/`node`/`npx` libres, clave capturada una sola vez y comprobada; ids de tarea validados (no se puede borrar fuera de la carpeta de trabajos); `lanzar` comprueba todo antes de crear nada; tope de tiempo que mata también a los procesos hijos.
- **Corregido:** los cambios del motor no se fusionaban (`git merge router/<id>` no hacía nada); Codex se colgaba esperando stdin en segundo plano; fallos silenciosos del motor; `cupo.py` roto por una línea rara y contaba GLM como Claude; ruta de repo inexistente operaba sobre el directorio actual.
- Opción `ROUTER_GLM_WRAP`: la clave de GLM se inyecta solo en el proceso de GLM desde tu gestor de contraseñas, sin pasar por el script.
- La tabla de reglas admite listas de motores por orden (mecánica → GLM, y Codex si no hay GLM).
- **Tarea atómica obligatoria** (`plantillas/tarea-atomica.md`): `lanzar` valida el formato y se niega si
  falta un apartado, hay más de 3 ficheros o no hay caso límite. Nuevo `validar`.
- **Tabla de reglas** (`reglas.json`, `regla`): tipo de tarea → motor recomendado, editable.
- **Reglas duras:** tarea sensible o difícil no sale de Claude; `ROUTER_NO_GLM` blinda rutas.
- **Segunda opinión:** `revisar` y `adversarial` (Codex en solo lectura).
- **Interruptor:** `apagar` / `encender`.
- **Cupo:** `cupo` e `informe` (+ `scripts/cupo.py`), guía para apuntarlo solo desde la barra de estado.
- **Política de modelos** (`referencias/politica-modelos.md`): plantilla por fase y por umbral de cupo.
- `motores.json` → `modelos.json` (solo motores externos; campos `strikes` y `como_se_invoca`). Migración automática.
- La regla de las 3 solo aplica a motores con `strikes: true`.

## 1.0 — 2026-09-27
- Primera versión pública: reparto a Codex y GLM en `git worktree`, veredictos, regla de las 3, `init`.
