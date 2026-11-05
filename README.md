# Vulnerability Tracker API

Тестовое задание Developer C#. Автор: **Ионов И.Э.**

Репозиторий: https://github.com/Ainzak/kasp-dev-dotnettest

REST API для добавления уязвимостей и управления асинхронными сканированиями.
Выполнены оба дополнительных задания: настраиваемый параллелизм с очередью и отмена ожидающего или запущенного сканирования.

**Сканер демонстрационный.** Он ждёт 5 секунд и возвращает две фиксированные находки с `isDemonstration: true`.
URL проверяется, но репозиторий не скачивается, доступность и права доступа к нему не проверяются, исходный код не выполняется.
Алгоритм анализа не задан в исходном ТЗ. Для подключения реального анализатора предусмотрен `IRepositoryScanner`.

## Требования и запуск

- .NET SDK **10.0.400**, указанный в `global.json`.
- Интернет для первоначального восстановления NuGet-пакетов.
- Для скрипта smoke-проверки — PowerShell 7. Для самого API PowerShell не требуется.

Из корня репозитория:

```shell
dotnet restore VulnerabilityTracker.sln --locked-mode
dotnet build VulnerabilityTracker.sln -c Release --no-restore
dotnet test --solution VulnerabilityTracker.sln -c Release --no-build
dotnet run --project src/VulnerabilityTracker.Api -c Release --no-build -- --urls http://localhost:5080
```

Остановить сервис можно через Ctrl+C. Адрес OpenAPI: http://localhost:5080/openapi/v1.json.
Документ доступен во всех окружениях; графический Swagger UI не добавлен.
В тестовом решении нет авторизации, база данных и внешние службы не нужны.

Для получения каталога, готового к запуску:

```shell
dotnet publish src/VulnerabilityTracker.Api -c Release --no-restore -o artifacts/publish
dotnet artifacts/publish/VulnerabilityTracker.Api.dll --contentRoot artifacts/publish --urls http://localhost:5080
```

## Настройки и хранение

В `src/VulnerabilityTracker.Api/appsettings.json`:

```json
{
  "Scanning": {
    "MaxParallelScans": 2
  }
}
```

`MaxParallelScans` — целое число больше нуля, по умолчанию `2`. Неверное значение предотвращает запуск.
Настройка применяется при старте; для изменения перезапустите сервис. Переопределение через переменную окружения:

```powershell
$env:Scanning__MaxParallelScans = '1'
dotnet run --project src/VulnerabilityTracker.Api -c Release --no-build -- --urls http://localhost:5080
```

В bash: `Scanning__MaxParallelScans=1 dotnet run --project src/VulnerabilityTracker.Api -c Release --no-build -- --urls http://localhost:5080`.

Уязвимости, очередь, задачи, результаты и объекты отмены находятся **только в памяти одного процесса**.
При каждом перезапуске состояние пустое; API не создаёт файлы результатов и не сохраняет репозитории на диск.
Очередь не ограничена по размеру, завершённые задачи сохраняются до остановки: решение рассчитано на объём тестового задания.
Для нескольких экземпляров приложения общее состояние не поддерживается.

Журналы выводятся в консоль: HTTP-метод, путь, код ответа, длительность, `TraceId`, переходы статусов и исключения.
Тела запросов не журналируются. Конфигурация логирования — в `appsettings.json`.
Артефакты сборки — в `bin/` и `obj/` проектов; локальные TRX-отчёты MSTest (при запуске с `--report-trx`) — в `tests/VulnerabilityTracker.Tests/bin/Release/net10.0/TestResults/`.
Эти каталоги исключены из Git. В CI TRX-отчёт публикуется отдельным артефактом.

## Контракт API

Все ID — GUID. Все даты — UTC, JSON в формате ISO 8601. Перечисления передаются строками, числовые значения не принимаются.

| Метод | Маршрут | Успешный ответ |
| --- | --- | --- |
| POST | `/api/vulnerabilities` | `201 Created`, запись и `Location` |
| GET | `/api/vulnerabilities/{id}` | `200 OK`, запись |
| POST | `/api/scans` | `202 Accepted`, задача и `Location` |
| GET | `/api/scans/{id}` | `200 OK`, состояние и результат/ошибка |
| POST | `/api/scans/{id}/cancel` | `200 OK`, результат попытки отмены |

Создание уязвимости:

```http
POST /api/vulnerabilities
Content-Type: application/json

{"name":"SQL injection","severity":"Critical"}
```

`name` обязателен, не состоит только из пробелов, имеет длину до 200 символов до удаления крайних пробелов.
`severity` обязателен: `Low`, `Medium`, `High`, `Critical`.

Пример ответа `201`:

```json
{
  "id": "ab08373c-454c-4e54-8cb0-44b4f35f4f11",
  "name": "SQL injection",
  "severity": "Critical",
  "createdAt": "2026-11-05T12:00:00+00:00"
}
```

По этому ID можно выполнить `GET /api/vulnerabilities/ab08373c-454c-4e54-8cb0-44b4f35f4f11`.

Запуск сканирования:

```http
POST /api/scans
Content-Type: application/json

{"repositoryUrl":"https://gitlab.com/example/repository"}
```

`repositoryUrl` — обязательный абсолютный HTTP/HTTPS URL. Запрос не ждёт завершения сканера.
Ответ `202` содержит `id`, нормализованный `repositoryUrl`, `status: "Queued"`, `updatedAt`, `result: null`, `error: null`.
По `Location` выполните GET. Работа могла уже перейти в `Running` к моменту чтения статуса.

Пример завершённой задачи:

```json
{
  "id": "9fd49a7b-8e35-4a3d-8d90-1fbd48451b61",
  "repositoryUrl": "https://gitlab.com/example/repository",
  "status": "Completed",
  "updatedAt": "2026-11-05T12:00:05+00:00",
  "result": {
    "isDemonstration": true,
    "findings": [
      {"name":"Demo: hard-coded credential","severity":"High","path":"demo/Configuration.cs","line":12},
      {"name":"Demo: unsafe SQL construction","severity":"Critical","path":"demo/Repository.cs","line":28}
    ]
  },
  "error": null
}
```

Находки не добавляются автоматически в реестр ручных уязвимостей.
При `Failed` поле `error` содержит безопасное описание, подробное исключение остаётся в журнале.

### Очередь и отмена

Переходы состояний: `Queued → Running → Completed/Failed`, а также `Queued/Running → Cancelled`.
Очередь FIFO: следующую ожидающую задачу получает первый освободившийся обработчик. Порядок завершения параллельных задач не гарантируется.

```http
POST /api/scans/9fd49a7b-8e35-4a3d-8d90-1fbd48451b61/cancel
```

```json
{
  "id": "9fd49a7b-8e35-4a3d-8d90-1fbd48451b61",
  "requestedAt": "2026-11-05T12:00:02+00:00",
  "success": true
}
```

`success: true` означает, что отмена выиграла переход в конечное состояние: задача получила `Cancelled`, сканеру передан сигнал отмены.
Ожидающая задача не попадёт в сканер. Активный демонстрационный сканер прервёт ожидание; слот освобождается только после его фактического выхода.
HTTP-ответ не ждёт выхода сканера. При замене сканера реализация обязана соблюдать переданный токен отмены.
Если завершение опередило отмену или задача уже отменена, возвращается `success: false`; состояние и его `updatedAt` не меняются.
При отмене результат никогда не публикуется. `requestedAt` — время текущей попытки отмены.
При остановке приложения ожидающая и активная работа отменяется, новые задачи не принимаются (`503`).

Для демонстрации очереди установите лимит `1`, быстро создайте три задачи, проверьте их статусы, отмените третью и первую.
Вторая начнётся после выхода первой и через 5 секунд вернёт результат. Готовые запросы — в `src/VulnerabilityTracker.Api/VulnerabilityTracker.Api.http`.
На свежем экземпляре сервиса с лимитом `2` весь сценарий можно выполнить командой:

```powershell
./scripts/SmokeTest.ps1 -BaseUrl http://localhost:5080
```

### Ошибки

Ошибочные данные или JSON возвращают `400`; неизвестный ID — `404`; неожиданные ошибки — `500`.
Ошибки имеют `Content-Type: application/problem+json` и поля `type`, `title`, `status`; при валидации добавляется `errors`.
Внутренние подробности не возвращаются. Ошибка конкретного сканирования меняет его статус на `Failed`, не останавливая очередь.

## Устройство решения и тесты

- `src/VulnerabilityTracker.Api/Vulnerabilities/` — неизменяемые записи, потокобезопасное хранилище и маршруты уязвимостей.
- `src/VulnerabilityTracker.Api/Scanning/` — снимки задач, атомарные переходы, очередь `Channel<Guid>`, фиксированный пул `BackgroundService`, интерфейс и демонстрационный сканер.
- `src/VulnerabilityTracker.Api/Infrastructure/` — журналирование запросов и единая обработка исключений.
- `tests/VulnerabilityTracker.Tests/` — модульные и HTTP-тесты на MSTest 4.1.0, `WebApplicationFactory` и управляемый сканер.
- `.github/workflows/ci.yml` — восстановление по lock-файлам, Release-сборка и MSTest в Linux.

Тесты проверяют валидацию, HTTP-контракты, UTC-время, неизменность снимков и результатов, переходы статусов,
лимит параллелизма, FIFO, отмену очереди и выполняющейся работы, гонку отмены с завершением,
восстановление обработки после ошибки, остановку и пустое состояние нового приложения.
Управляемые сканеры синхронизируются сигналами, без ожидания реальных 5 секунд; ожидания ограничены тайм-аутами.
Версии SDK и пакетов зафиксированы в `global.json`, проектах и `packages.lock.json`.
