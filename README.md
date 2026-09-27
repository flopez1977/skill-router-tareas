# router-tareas — skill para Claude Code

Reparte las tareas de un plan entre **Claude**, **Codex** (con tu suscripción de ChatGPT) y
**GLM** (con el GLM Coding Plan de z.ai). Cada tarea se hace en una copia aislada del repo
(`git worktree`), Claude revisa siempre el resultado antes de aceptarlo, y el motor que falla
tres veces en 30 días sale solo del reparto.

La idea: aprovechar las suscripciones de tarifa plana que ya pagas para no quemar el límite de
Claude en trabajo que otro modelo hace igual de bien, sin perder calidad.

## Instalación

```bash
git clone https://github.com/flopez1977/skill-router-tareas.git
cp -r skill-router-tareas/router-tareas ~/.claude/skills/
```

La primera vez que la uses, Claude te preguntará qué suscripciones tienes (ChatGPT, z.ai, las dos
o ninguna) y activará solo esos motores. Sin ninguna también funciona: lo hace todo Claude.

Después, una vez: `npm i -g @openai/codex && codex login` (Codex) y la clave de z.ai en
`ZAI_API_KEY` o en un comando (`ROUTER_GLM_KEY_CMD`) que la saque de tu gestor de contraseñas.

## Uso

Pídeselo a Claude con naturalidad: *«reparte las tareas del plan con el router»*,
*«pásale la tarea 3 a Codex»*. Las reglas de reparto, la plantilla de prompt, la revisión y la
regla de las 3 están en [`router-tareas/SKILL.md`](router-tareas/SKILL.md).

```bash
router.sh estado
router.sh lanzar codex ~/proyecto T3 prompt.md 30
router.sh veredicto T3 ok        # o: mal "cambió el test para que pasara"
router.sh limpiar T3
```

## Requisitos

macOS o Linux con `git`, `python3`, `perl` y Claude Code. Codex CLI y/o suscripción a z.ai para
los motores que quieras usar (puedes quitar cualquiera en `~/.router-tareas/motores.json`).

## Licencia

MIT.
