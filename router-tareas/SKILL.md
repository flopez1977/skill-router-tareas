---
name: router-tareas
description: Reparte tareas ya identificadas de un plan entre Claude, Codex (suscripción de ChatGPT) y GLM (z.ai Coding Plan), cada una en una copia aislada del repo, con Claude revisando siempre el resultado y sacando del reparto al motor que falle tres veces. Úsala cuando haya un plan con varias tareas de código concretas y comprobables y quieras ahorrar el límite de Claude, cuando el usuario diga "reparte las tareas", "pásaselo a Codex", "que lo haga GLM", "usa el router", "router de tareas", o cuando pregunte cómo combinar varias suscripciones de IA para programar. No la uses para tareas pequeñas, sensibles o que necesitan todo el contexto de la conversación.
---

# Router de tareas: Claude reparte, Codex y GLM ejecutan, Claude revisa

Tienes varias suscripciones de tarifa plana (Claude, ChatGPT, z.ai) y un plan con tareas ya
definidas. En vez de gastar todo el límite de Claude, Claude se queda lo que requiere criterio y
reparte lo acotado y lo mecánico. **Nunca se acepta un resultado sin que Claude lo revise.**

No hace falta tener sesiones abiertas con los otros modelos: los dos arrancan bajo demanda, hacen
la tarea y terminan. Tenerlos abiertos a mano solo mezcla contextos entre tareas.

## 1. Quién hace qué

| Motor | Recibe | No recibe nunca |
|---|---|---|
| **Claude** | Planificar, arquitectura, seguridad, credenciales, producción, fallos sin causa clara, textos para clientes y **la revisión final de todo** | — |
| **Codex** (ChatGPT) | Implementación acotada con tests: una función, un endpoint, un refactor de pocos ficheros; segunda opinión dura sobre un cambio | Secretos; nada que toque producción |
| **GLM** (z.ai) | Mecánico en volumen: renombrados, código repetitivo, migrar formatos, tests sencillos, documentar código | Datos personales, salud, pagos o código sensible de clientes |

## 2. Cuándo NO se reparte

- **Si revisar, mandar y organizar va a costar más que hacerlo.** Tareas de menos de ~10 minutos
  o que necesitan todo el contexto de la conversación: las hace Claude directamente.
- Cambios que cruzan muchos ficheros o sin forma clara de comprobarse (sin tests ni criterio de
  aceptación verificable).
- Repos con ficheros sensibles trackeados (`.env`, claves): el script se niega solo.
- Datos que no deben salir a ese proveedor (ver §7).

## 3. La regla de las 3

Cada tarea termina con un **veredicto** de Claude: `ok` o `mal` con motivo. Es `mal` si la
calidad es peor que la que habría dado Claude, si hubo que rehacerla, si tocó tests para ponerlos
en verde o si dio más guerra de la que ahorró. **Tres `mal` en 30 días sacan al motor del reparto
automáticamente.** Solo vuelve cuando el usuario lo decide (`router.sh activar <motor>`). Los
motores se quitan o se añaden editando `~/.router-tareas/motores.json`.

## 4. Cómo se hace (paso a paso, lo ejecuta Claude)

```bash
R=<ruta de esta skill>/scripts/router.sh
$R init                                    # la primera vez
$R estado                                  # qué motores están activos y cómo van
```

Para cada tarea que decidas repartir:

1. **Escribe el prompt** en un fichero, con esta plantilla:
   ```
   Objetivo: <qué hay que conseguir, en una frase>
   Ficheros: <los que puede tocar>
   Criterio de aceptación: <comando exacto que tiene que pasar, p. ej. `npm test -- slug`>
   Casos límite que debe cubrir: <los raros, explícitos — sin esto GLM los resuelve a medias>
   Reglas: NO modifiques tests existentes. No añadas dependencias. No toques ficheros fuera de la lista.
   ```
2. **Lanza** en una copia aislada (git worktree en la rama `router/<id>`):
   `$R lanzar codex <repo> <id> prompt.md 30` (el último número es el tope en minutos).
3. **Revisa tú** (Claude), sin fiarte de lo que diga el motor:
   - `git -C ~/.router-tareas/trabajos/<id>/wt diff --cached HEAD` y léelo entero;
   - comprueba que **no se ha tocado ningún test** existente;
   - pasa **tú** los tests del criterio de aceptación dentro del worktree;
   - piensa en los casos que los tests no cubren.
4. **Veredicto:** `$R veredicto <id> ok` o `$R veredicto <id> mal "motivo concreto"`.
5. Si es `ok`: `git -C <repo> merge router/<id>`. Si es `mal`: o se reintenta una vez con un
   prompt mejor, o la hace Claude.
6. `$R limpiar <id>`.

Puedes lanzar varias tareas independientes en paralelo (cada una en su worktree), pero revisa
y fusiona de una en una.

## 5. Configuración inicial (una vez)

- **Codex:** `npm i -g @openai/codex` y `codex login` con tu cuenta de ChatGPT.
- **GLM:** suscripción GLM Coding Plan en z.ai (el plan básico basta para trabajo mecánico) y la
  clave disponible como `ZAI_API_KEY`, o mejor mediante un comando que la saque de tu gestor de
  contraseñas: `export ROUTER_GLM_KEY_CMD='security find-generic-password -s zai -w'` (macOS) —
  así la clave nunca queda escrita en un fichero ni en el historial.
- Requisitos: `git`, `python3`, `perl` y Claude Code.

## 6. Qué dice la experiencia

- En una prueba con una función y cuatro tests, **Codex** la resolvió limpia en 25 s. **GLM** también
  pasó los tests (81 s) pero con una solución peor en un caso que los tests no cubrían. Conclusión:
  con GLM, los casos límite tienen que ir escritos en el criterio de aceptación.
- Estudios independientes han visto a Codex **cambiar código correcto para que pase un test
  equivocado** y obedecer en silencio instrucciones contradictorias. Por eso la revisión es de
  Claude, siempre, y por eso se comprueba que los tests no se han tocado.

## 7. Datos y privacidad

- **ChatGPT/Codex:** desactiva en la configuración de datos de ChatGPT «Mejorar el modelo para
  todos» (y lo equivalente en Codex) si no quieres que se entrene con tu código.
- **z.ai (GLM):** empresa con sede en Singapur y matriz china (Zhipu). No le mandes datos personales
  de clientes, datos de salud o de pagos, ni código sensible.
- Nunca pongas secretos en el prompt. Si una tarea necesita una credencial, la hace Claude.
- El worktree solo contiene ficheros **trackeados**: tus `.env` sin trackear no viajan, pero
  compruébalo antes de lanzar.
