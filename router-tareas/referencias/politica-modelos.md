# Política de modelos de Claude: qué modelo hace qué

**Es una plantilla: edítala con tus reglas.** Cambiarla es editar una tabla, no código. Los motores
externos (Codex, GLM) no van aquí, sino en `~/.router-tareas/modelos.json`. Los nombres de modelo
son alias de Claude Code (`opus`, `sonnet`, `fable`…), que apuntan siempre al último de cada familia;
si sale un modelo nuevo, cambia el alias o el nombre de esta tabla y ya está.

> Contexto de esta plantilla: se escribió cuando Opus era el modelo caro y Sonnet el barato. Si tus
> modelos se llaman distinto, mantén la idea: **el caro solo donde su calidad se nota; el barato
> para el resto.**

## 1. Por fase de trabajo

| Fase | Modelo por defecto | Cuándo sube o baja |
|---|---|---|
| Planificar | El caro (`opus`), en un subagente | Plan pequeño → el barato |
| Descomponer en tareas atómicas | El barato (`sonnet`) con la plantilla de tarea | Más de ~10 tareas → el caro |
| Implementar | El barato | Mecánico y en volumen → GLM · acotado, con tests y sin datos sensibles → Codex · muy difícil → el caro |
| Revisar | Un modelo distinto del que escribió (p. ej. el caro) | Antes de producción, además `router.sh adversarial` |
| Verificar | Claude ejecuta los tests él mismo | Siempre |

## 2. Por tipo de trabajo (se decide AL ABRIR la sesión)

Pon aquí lo que tú consideres que no admite recortes. Ejemplo:

| Trabajo | Modelo de sesión |
|---|---|
| Trabajo que ve el cliente y donde la calidad se nota (diseño, textos de venta) | El caro, sin límite por cupo |
| Automatizaciones, informes, mantenimiento, tareas mecánicas | El barato |
| Depurar sin causa clara, arquitectura, plan grande | El caro |

**Regla:** el modelo se decide al abrir la sesión. **Cambiarlo a mitad reescribe la caché de
contexto entera** y cuesta como empezar de nuevo: si hay que cambiar, `/compact` o una sesión nueva.
Para que las sesiones nuevas arranquen en el modelo barato, ponlo en `~/.claude/settings.json`:
`"model": "sonnet"`.

## 3. Cupo semanal (si tu plan tiene límite)

Mide con `router.sh cupo` / `router.sh informe` (ver `cupo-barra.md`). Umbrales de ejemplo, ajústalos:

| Uso semanal | Modo |
|---|---|
| < 60 % | Normal |
| 60-80 % | El caro solo para planificar y para el trabajo que ve el cliente |
| > 80 % | El caro solo con permiso del usuario; implementación al barato / Codex / GLM |

Se **proponen**, no se imponen: mejor que Claude avise («vamos al 82 %, ¿paso a implementar con
Sonnet?») a que cambie solo. Y el trabajo que has marcado como «sin recortes» queda fuera del modo ahorro.

**Ojo, no está probado que cambiar de modelo mueva tu cupo.** En las mediciones del autor de esta skill
(una semana de sesiones propias, sin más muestra), la lectura de caché de contexto pesaba unas 7 veces
más que la salida a precio de API, y cuesta igual en un modelo que en otro. Puede no ser tu caso. Antes de fiarte de un umbral, mira tu propia serie de `router.sh informe`.

## 4. No se reparte si…

Coordinar y revisar cuesta más que hacerlo (tareas de menos de ~10 minutos, o que necesitan todo el
contexto de la sesión). Claude revisa **siempre** lo que hagan los demás.

## 5. Alta de un modelo nuevo (lista de comprobación)

1. **De Claude:** una línea en las tablas 1 y 2 con el alias.
2. **Externo:** una entrada en `~/.router-tareas/modelos.json` (`activo`, `para`, `como_se_invoca`,
   `strikes`) y su rama en el `case` de `lanzar` en `router.sh`.
3. Dale 3-5 tareas reales tuyas; anota tiempo, cupo y si sale bien a la primera; compáralo con el
   modelo al que sustituiría.
4. Cambia la tabla solo si mejora **con tus datos**, no con los del fabricante.
