# router-tareas — skill para Claude Code

Reparte las tareas de un plan entre **Claude**, **Codex** (con tu suscripción de ChatGPT) y
**GLM** (con el GLM Coding Plan de z.ai). Cada tarea se hace en una copia de trabajo del repo
(`git worktree`, otra carpeta y otra rama), Claude revisa siempre el resultado antes de aceptarlo, y el motor que falla
tres veces en 30 días sale solo del reparto.

La idea: aprovechar las suscripciones de tarifa plana que ya pagas para no quemar el límite de
Claude en trabajo que otro modelo hace igual de bien, sin perder calidad. Y, si tu plan de Claude
tiene límite semanal, **medir qué lo gasta de verdad** antes de decidir qué cambiar.

## Qué incluye

| | |
|---|---|
| **Reparto seguro** | Tarea atómica con formato obligatorio, tabla de reglas (mecánica → GLM, acotada → Codex, difícil o sensible → Claude), copia aislada, revisión de Claude siempre |
| **Regla de las 3** | 3 veredictos «mal» en 30 días y el motor sale solo; solo vuelve si tú lo decides |
| **Tabla final** | `resumen`: al acabar, qué se mandó a cada motor, cuánto tardó y cómo salió la revisión de Claude |
| **Segunda opinión** | `revisar` y `adversarial`: Codex, sin permiso de escritura, busca fallos que tu modelo no ve |
| **Interruptor** | `apagar` / `encender`: vuelves a trabajar como antes en un comando |
| **Cupo** | `cupo` e `informe` apuntan tu % semanal junto al reparto de uso por modelo |
| **Política de modelos** | Plantilla: qué modelo de Claude en cada fase y qué hacer según el % de cupo |

## Instalación

```bash
git clone https://github.com/flopez1977/skill-router-tareas.git
cp -r skill-router-tareas/router-tareas ~/.claude/skills/
```

La primera vez que la uses, Claude te preguntará qué suscripciones tienes (ChatGPT, z.ai, las dos
o ninguna) y activará solo esos motores. Sin ninguna también funciona: lo hace todo Claude.

Después, una vez: `npm i -g @openai/codex && codex login` (Codex) y la clave de z.ai en
`ZAI_API_KEY` o en un comando (`ROUTER_GLM_KEY_CMD`) que la saque de tu gestor de contraseñas.
Si ya tenías la versión 1 instalada, `router.sh` migra tu configuración (`motores.json` →
`modelos.json`) la primera vez que se ejecuta cualquier comando.

## Uso

Pídeselo a Claude con naturalidad: *«reparte las tareas del plan con el router»*,
*«pásale la tarea 3 a Codex»*, *«pídele a Codex una segunda opinión»*, *«apaga el router»*.
Las reglas de reparto, la revisión y la regla de las 3 están en
[`router-tareas/SKILL.md`](router-tareas/SKILL.md).

```bash
R=~/.claude/skills/router-tareas/scripts/router.sh
$R estado                                # motores y cómo van (avisa si está apagado)
$R validar tarea.md                      # comprueba el formato de tarea atómica
$R regla acotada                         # motor que recomienda la tabla
$R lanzar codex ~/proyecto T3 tarea.md 30
$R veredicto T3 ok                       # o: mal "cambió el test para que pasara"
$R limpiar T3
$R resumen                               # tabla final del reparto (qué se mandó, cuánto tardó, cómo salió)
$R adversarial ~/proyecto main           # segunda opinión, sin permiso de escritura
$R apagar | encender                     # interruptor general
$R cupo 81 ; $R informe                  # cupo semanal
```

## Qué te protege (y qué no)

Reglas duras del script, que Claude no puede saltarse:

- Una tarea marcada **sensible** no sale de Claude. Una tarea **difícil**, tampoco.
- **GLM** no trabaja en las rutas que pongas en `ROUTER_NO_GLM` (sus datos salen a un tercero).
- Se niega a repartir un repo con ficheros sensibles trackeados (`.env`, claves).
- `revisar` y `adversarial` corren sin permiso de escritura.
- La clave de GLM solo vive en el entorno del proceso hijo, nunca se imprime y se comprueba que no esté vacía.
- GLM corre con un `HOME` desechable: no ve tu `CLAUDE.md` global, tus servidores MCP ni tus hooks.
- Un id de tarea no puede contener rutas (no se puede borrar nada fuera de `~/.router-tareas/trabajos`).

**Límites, dichos sin rodeos.** El worktree separa los *cambios*, no las *lecturas*: un motor con
acceso a tu disco puede leer archivos fuera de la copia (por ejemplo el `.env` sin trackear de tu
repo), y lo que lee puede ir a OpenAI o a z.ai. No hay aislamiento de red. Si eso te importa, ejecuta el
router en un contenedor o una máquina virtual, o no repartas esas tareas. Detalle en la sección 9 de
[`SKILL.md`](router-tareas/SKILL.md). La regla es siempre la misma: **Claude lee el diff y pasa los
tests él mismo antes de fusionar.**

## Requisitos

macOS o Linux con `git`, `python3`, `perl` y Claude Code (y `jq` si activas el apunte automático del
cupo). Codex CLI y/o suscripción a z.ai para los motores que quieras usar. Configuración en
`~/.router-tareas/` (cámbiala con `ROUTER_HOME`): `modelos.json` (motores) y `reglas.json` (tabla de reglas).

## Licencia

MIT. Cambios en [`CHANGELOG.md`](CHANGELOG.md).
