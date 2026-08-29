# OpenTelemetry Zig Cache API

`ObservableGauge`を使用するインメモリHTTPキャッシュです。サーバー停止時にデータは消えます。

## Requirements

- Zig 0.16.0
- Internet access for the first build

依存は`build.zig.zon`で固定しています。

- [`open-telemetry/opentelemetry-zig`](https://github.com/open-telemetry/opentelemetry-zig): [Apache-2.0](https://github.com/open-telemetry/opentelemetry-zig/blob/24454791d67c8468783c8b2253cd9719ee02a502/LICENSE)
- [`karlseguin/http.zig`](https://github.com/karlseguin/http.zig): [MIT](https://github.com/karlseguin/http.zig/blob/9b14af98fde5e98abb9a8376fe02b42003e835bf/LICENSE)

## Run

```sh
zig build run
```

`http://127.0.0.1:8080`で待ち受けます。

## API

| Method | Path | Result |
| --- | --- | --- |
| `GET` | `/` | Route list |
| `PUT` | `/items/{key}` | Store the request body |
| `GET` | `/items/{key}` | Read a value |
| `DELETE` | `/items/{key}` | Delete a value |
| `GET` | `/debug/metrics` | Collect and return metrics |

キーには英数字、`-`、`_`を使用でき、上限は64バイトです。値は1件4096バイト、キャッシュは1024件・合計4 MiBまでです。

## Metrics

| Name | Instrument | Value |
| --- | --- | --- |
| `cache.entries` | `ObservableGauge` | Cached item count |
| `cache.bytes` | `ObservableGauge` | Cached value bytes |
| `http.requests` | `Counter` | Handled request count |

`GET /debug/metrics`が収集を開始し、Observable callbackが現在のキャッシュ状態を読みます。このリクエストも`http.requests`に含まれます。

## Zig patterns

| Code | Pattern |
| --- | --- |
| `CacheStats.from(anytype)` | Compile-time duck typing |
| `*const anyopaque` + `VTable` | Runtime interface and type erasure |
| `StringHashMapUnmanaged` + `Allocator` | Explicit allocation |
| `defer` + `errdefer` | Cleanup and rollback |
| `?T` + `orelse`, `E!T` + `try`/`catch` | Optional and error handling |
| `switch` on `MeasurementsData` | Tagged union |
| `@TypeOf`, `@typeInfo`, `@FieldType` | Compile-time reflection |

## Test

```sh
zig build test
```

## License

[Apache-2.0](LICENSE)

## TODO

### Cache hit/miss metrics

- [ ] `GET /items/{key}`のhitとmissを記録する
- [ ] `/debug/metrics`へ結果を追加する
- [ ] Counterの累計をテストする

### Request duration

- [ ] HTTP処理時間をHistogramへ記録する
- [ ] 単位を決める
- [ ] 収集結果をテストする

### List keys

- [ ] `Cache`からキー一覧を取得する
- [ ] `GET /items`でJSONを返す
- [ ] 空と複数項目をテストする

### Configurable port

- [ ] `--port`を受け取る
- [ ] 不正な値を拒否する

### Persistence

- [ ] キャッシュの変更をファイルへ保存する
- [ ] 起動時に復元する
- [ ] 再起動後も値が残ることをテストする
