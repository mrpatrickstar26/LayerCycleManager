Ниже — подробный roadmap именно под твою задачу: **не запускать Python из AutoCAD**, а **переписать саму логику** программы на нативные инструменты AutoCAD, чтобы это ставилось как menuGEO: папка с файлами, подгрузка через `CUIX`, минимум зависимостей, работа на других компьютерах.

---

# 1. Рекомендуемый стек технологий

## Основной вариант: AutoLISP / Visual LISP + DCL + CUIX

Для твоей задачи оптимально использовать:

| Компонент | Технология | Зачем |
|---|---|---|
| Логика программы | **AutoLISP / Visual LISP** | Чтение слоёв, точек, текстов, построение линий, solid-треугольников, текста |
| Работа с объектами AutoCAD | **ActiveX / COM через `vlax-` и `vla-`** | Создание `Line`, `Solid`, `Text`, работа со слоями, цветами, TrueColor |
| Интерфейс | **DCL** | Нативные диалоги AutoCAD: списки слоёв, поля ввода, кнопки, listbox |
| Интеграция в интерфейс AutoCAD | **Partial CUIX** | Своя вкладка/панель/кнопка, как у menuGEO |
| Настройки | Текстовый `.cfg` или `.lsp`-config | Хранение последних слоёв, масштаба, цвета, высоты текста |
| Защита кода, опционально | **FAS / VLX** | Компиляция LISP, чтобы не отдавать исходники |
| Загрузка | `_menuload`, `APPLOAD`, support path | Установка без инсталлятора |

### Почему не Python / pyautocad

Python-вариант требует:

- установленный Python;
- `pyautocad`;
- возможно `ezdxf`;
- COM-мост;
- зависимости на каждом компьютере;
- отдельный Tkinter-процесс.

Это не соответствует требованию «скопировал папку и работает».

### Почему не ObjectARX / C++

ObjectARX — избыточно:

- нужен Visual Studio C++;
- жёсткая привязка к версии AutoCAD;
- сложная отладка;
- для такой задачи производительность не нужна.

### Когда имеет смысл AutoCAD.NET + WPF

Если DCL окажется слишком примитивным и захочется:

- красивый современный интерфейс;
- полноценную таблицу сопоставлений с combobox прямо в строках;
- удобный RGB color picker;
- drag-and-drop;
- сложные окна.

Тогда можно делать **Plan B**: C# + AutoCAD.NET + WPF. Но для первой нативной версии я рекомендую именно **AutoLISP + DCL + CUIX**, потому что это ближе всего к menuGEO и проще для переноса на другие машины.

---

# 2. Целевая архитектура программы

Назовём программу, например, **Layer Cycle Manager**, сокращённо `LCM`.

## Структура папки

```text
LayerCycleManager/
│
├── lcm_main.lsp          ; точка входа, команда LCM, загрузка модулей
├── lcm_config.lsp        ; чтение/запись настроек
├── lcm_data.lsp          ; получение слоёв, точек, текстов, сопоставления
├── lcm_core.lsp          ; математика и отрисовка стрелок
├── lcm_ui.lsp            ; логика DCL-диалога
├── lcm_ui.dcl            ; описание диалога
│
├── lcm.cuix              ; частичный файл интерфейса AutoCAD
│
├── icons/
│   ├── lcm_16.bmp
│   └── lcm_32.bmp
│
├── settings/
│   └── lcm_settings.cfg  ; создаётся автоматически
│
├── loader/
│   └── lcm_loader.lsp    ; опциональный первичный загрузчик
│
└── README.txt
```

## Логическая схема

```text
Пользователь нажимает кнопку в Ribbon
        ↓
CUIX-макро подгружает lcm_main.lsp
        ↓
Команда LCM открывает DCL-диалог
        ↓
Диалог:
- выбирает слои;
- получает точки с нулевого и последнего слоя;
- делает авто-сопоставление;
- позволяет вручную сопоставить точки;
- задаёт цвет, высоту текста, масштаб;
        ↓
После OK вызывается ядро:
- читает координаты;
- строит линию;
- строит залитый треугольник;
- добавляет текст длины в мм;
        ↓
Объекты помещаются на выбранный слой
```

---

# 3. Ключевое требование: как это должно устанавливаться

Есть важный момент:

> Команда `_menuload` загружает именно `CUIX`, то есть файл интерфейса.  
> Она сама по себе не загружает LISP-код.

Поэтому нужна одна из двух схем.

---

## Схема A. Рекомендуемая: Support Path + CUIX

Пользователь:

1. Копирует папку `LayerCycleManager` на компьютер.
2. Добавляет эту папку в **Support File Search Path**.
3. Загружает `lcm.cuix` через `_menuload`.
4. Получает кнопку в Ribbon.
5. Кнопка сама подгружает LISP по имени файла, потому что папка уже есть в путях AutoCAD.

Это самый чистый и menuGEO-подобный вариант.

### Плюс

- не нужно хранить абсолютные пути;
- можно переносить папку;
- LISP-файлы находятся по имени;
- легко обновлять.

### Минус

- один раз нужно добавить папку в Support Path.

---

## Схема B. Loader без Support Path

Пользователь:

1. Копирует папку.
2. Один раз загружает `lcm_loader.lsp` через `APPLOAD` или перетаскиванием в AutoCAD.
3. Loader спрашивает путь к папке.
4. Loader сохраняет путь, например, в переменную окружения или текстовый файл.
5. Loader сам загружает LISP и CUIX.

### Плюс

- не нужно вручную добавлять Support Path.

### Минус

- всё равно нужно один раз загрузить loader;
- где-то надо хранить указатель на папку;
- чуть сложнее для пользователей.

---

## Мой вывод

Для финальной версии делай **обе схемы**, но основной считай **Support Path + CUIX**.

В `README.txt` можно написать:

> Добавьте папку LayerCycleManager в Support File Search Path, затем выполните `_menuload` и загрузите `lcm.cuix`.

---

# 4. Roadmap: полный план реализации

---

# Этап 0. Подготовить требования и тестовый чертёж

## 0.1. Зафиксировать логику из Python

Нужно явно сохранить правила:

### Входные данные

- слой нулевого цикла;
- слой последнего цикла;
- точки `AcDbPoint`;
- подписи `AcDbText` или `AcDbMText`;
- радиус поиска подписи: например, `50` единиц чертежа;
- если подпись не найдена, имя точки = `Точка_<Handle>`.

### Сопоставление

- авто-сопоставление по одинаковым именам;
- ручное сопоставление;
- удаление сопоставлений;
- очистка всех сопоставлений;
- если точка в последнем слое не найдена — показать placeholder, например, `не найдено`.

### Отрисовка

- линия рисуется от `start_point` до:
  ```text
  C = start + (end - start) * scale
  ```
- длина подписывается по исходным точкам, без учёта `scale`;
- длина в мм:
  ```text
  length_mm = round(length_m * 1000)
  ```
- наконечник:
  - угол при вершине 20°;
  - по 10° от оси;
  - длина крыла = `0.2 * length * scale`;
- наконечник — залитый треугольник `AcDbSolid`;
- текст размещается в точке острия.

### Цвет

Три режима:

1. **ByLayer**
   - цвет объекта = цвет слоя;
   - AutoCAD Color Index = `256`.

2. **ACI**
   - индекс AutoCAD от 1 до 255.

3. **RGB**
   - TrueColor;
   - задаётся через R, G, B;
   - в AutoLISP можно реализовать через `TrueColor` объект.

### Параметры

- масштаб > 0;
- высота текста > 0;
- цвет ACI от 1 до 255;
- RGB от 0 до 255.

## 0.2. Сделать тестовый DWG

Создай тестовый чертёж:

- слой `0 цикл`;
- слой `2 цикл`;
- несколько точек на каждом слое;
- текстовые подписи рядом: `1`, `2`, `3`;
- точки с разными именами, чтобы проверить ручное сопоставление;
- точки без текста, чтобы проверить fallback `Точка_<Handle>`.

## 0.3. Определиться с версией AutoCAD

Минимально ориентируйся на:

```text
AutoCAD 2018+
```

Причины:

- `CUIX` как основной формат;
- нормальная работа Ribbon;
- Visual LISP ActiveX доступен.

Важно:

> AutoCAD LT — плохая цель для этой задачи.  
> В LT ограничения по ActiveX, .NET, полноценной автоматизации и некоторым механизмам.  
> Делай под полный AutoCAD.

---

# Этап 1. Настройка среды разработки

## 1.1. Установить AutoCAD

Нужен полный AutoCAD, не LT.

Проверь команды:

```text
APPLOAD
VLIDE
CUI
MENULOAD
TRUSTEDPATHS
SECURELOAD
```

## 1.2. Установить VSCode

VSCode подойдёт как редактор.

Рекомендуемые расширения:

1. **AutoLISP** от Autodesk или аналогичное.
2. Расширение для DCL, если найдёшь.
3. Git.
4. EditorConfig, опционально.

## 1.3. Настроить кодировку

Это важно для русского языка.

Для AutoLISP/DCL в русской локали AutoCAD обычно безопаснее:

```text
Windows-1251 / ANSI
```

В VSCode можно задать:

```json
{
  "files.associations": {
    "*.lsp": "lisp",
    "*.dcl": "lisp"
  },
  "[lisp]": {
    "files.encoding": "windows1251"
  }
}
```

Если будешь сохранять в UTF-8 без BOM, сначала проверь, что русские строки нормально отображаются в AutoCAD.

## 1.4. Создать проект

Создай папку:

```text
LayerCycleManager/
```

Сделай git:

```bash
git init
```

Создай пустые файлы:

```text
lcm_main.lsp
lcm_config.lsp
lcm_data.lsp
lcm_core.lsp
lcm_ui.lsp
lcm_ui.dcl
README.txt
```

## 1.5. Добавить папку в Support Path

В AutoCAD:

```text
OPTIONS → Files → Support File Search Path → Add
```

Добавь папку `LayerCycleManager`.

Также желательно добавить её в Trusted Locations:

```text
OPTIONS → Files → Trusted Locations
```

Или через переменные:

```text
TRUSTEDPATHS
SECURELOAD
```

Не советую просто выключать `SECURELOAD`, лучше добавить папку в доверенные.

## Результат этапа

- VSCode настроен;
- AutoCAD видит папку;
- есть тестовый DWG;
- есть пустая структура проекта.

---

# Этап 2. Сделать каркас программы и команду LCM

## 2.1. Создать точку входа

Файл `lcm_main.lsp`:

```lisp
;;; ============================================================
;;; Layer Cycle Manager
;;; Главный файл
;;; ============================================================

(vl-load-com)

;;; Глобальные переменные лучше держать с префиксом lcm:
(setq lcm:version "0.1.0")

(defun C:LCM ()
  (lcm:start)
  (princ)
)

(defun lcm:start ()
  (prompt "\nLayer Cycle Manager загружен. Версия: ")
  (prompt lcm:version)
  (prompt "\n")
  (princ)
)

(princ)
```

## 2.2. Загрузить вручную

В AutoCAD:

```text
APPLOAD → lcm_main.lsp
```

Или из командной строки:

```lisp
(load "lcm_main.lsp")
```

Затем:

```text
LCM
```

Должно появиться сообщение в командной строке.

## 2.3. Проверить, что команда доступна

Выполни:

```text
LCM
```

Если работает — каркас готов.

## Результат этапа

- есть команда `LCM`;
- файл загружается;
- AutoCAD реагирует;
- можно дальше наращивать модули.

---

# Этап 3. Перенести ядро логики с Python на Visual LISP

Это самый важный этап.

Не пытайся сразу сделать весь интерфейс. Сначала перенеси функции:

1. получение слоёв;
2. получение точек с именами;
3. сортировка имён;
4. отрисовка одной стрелки;
5. отрисовка всех стрелок по списку сопоставлений.

---

## 3.1. Модуль данных: `lcm_data.lsp`

### Функция получения слоёв

Аналог Python:

```python
get_all_layers()
```

На LISP:

```lisp
(defun lcm:get-layers (/ acad doc layers)
  (setq acad (vlax-get-acad-object))
  (setq doc (vla-get-ActiveDocument acad))
  (setq layers '())

  (vlax-for layer (vla-get-Layers doc)
    (setq layers (cons (vla-get-Name layer) layers))
  )

  (acad_strlsort layers)
)
```

Использование:

```lisp
(setq all-layers (lcm:get-layers))
```

---

## 3.2. Получение точек и текстов со слоя

Аналог Python:

```python
get_points_with_names(layer_name)
```

Нужно реализовать:

- перебрать объекты ModelSpace или активного Layout;
- отобрать объекты нужного слоя;
- найти `AcDbPoint`;
- найти `AcDbText`, `AcDbMText`;
- для каждой точки найти ближайший текст в радиусе, например, 50;
- вернуть список вида:

```lisp
(
  ("1" . (100.0 200.0))
  ("2" . (150.0 220.0))
  ("Точка_1A2B" . (180.0 260.0))
)
```

### Важные ActiveX-свойства

Для точек:

```lisp
ObjectName = "AcDbPoint"
Coordinates
Handle
```

Для текста:

```lisp
ObjectName = "AcDbText" или "AcDbMText"
TextString
InsertionPoint
```

### Пример вспомогательной функции получения координат

```lisp
(defun lcm:get-coords (obj / res)
  (setq res
    (vl-catch-all-apply
      (function
        (lambda ()
          (vlax-safearray->list
            (vlax-variant-value
              (vla-get-Coordinates obj)
            )
          )
        )
      )
    )
  )

  (if (vl-catch-all-error-p res)
    (setq res
      (vl-catch-all-apply
        (function
          (lambda ()
            (vlax-safearray->list
              (vlax-variant-value
                (vla-get-InsertionPoint obj)
              )
            )
          )
        )
      )
    )
  )

  (if (vl-catch-all-error-p res)
    nil
    res
  )
)
```

Это черновой вариант. В продакшене лучше вынести в отдельный модуль и аккуратно обрабатывать ошибки.

---

## 3.3. Поиск ближайшего текста

Логика:

```lisp
для каждой точки:
  min_dist = infinity
  best_text = nil
  для каждого текста:
    dist = distance(point, text_insertion)
    if dist < min_dist and dist < search_radius:
      min_dist = dist
      best_text = text_string
  if best_text:
    name = best_text
  else:
    name = "Точка_" + handle
```

На LISP это реализуется через `vl-sort`, `distance`, `assoc`, списки.

Рекомендую хранить точки так:

```lisp
(setq points-raw
  (list
    (list :x 100.0 :y 200.0 :handle "1A2B")
    (list :x 150.0 :y 220.0 :handle "1C3D")
  )
)
```

Тексты:

```lisp
(setq texts-raw
  (list
    (list :text "1" :x 101.0 :y 201.0)
    (list :text "2" :x 151.0 :y 221.0)
  )
)
```

Потом собрать:

```lisp
(setq points-named
  (list
    (cons "1" (list 100.0 200.0))
    (cons "2" (list 150.0 220.0))
  )
)
```

---

## 3.4. Сортировка имён

В Python у тебя было:

```python
def sort_key(name):
    try:
        return (0, float(name))
    except:
        return (1, name)
```

На LISP можно сделать так:

```lisp
(defun lcm:is-number-string (s / num)
  (setq num (distof s 2))
  (if num T nil)
)

(defun lcm:sort-names (names)
  (vl-sort names
    (function
      (lambda (a b / na nb)
        (setq na (lcm:is-number-string a))
        (setq nb (lcm:is-number-string b))

        (cond
          ;; оба числа
          ((and na nb)
           (< (atof a) (atof b))
          )

          ;; только a число
          (na T)

          ;; только b число
          (nb nil)

          ;; обе строки
          (T
           (< (strcase a) (strcase b))
          )
        )
      )
    )
  )
)
```

---

## 3.5. Модуль отрисовки: `lcm_core.lsp`

Аналог Python:

```python
draw_arrow(...)
```

Нужно реализовать:

```lisp
(lcm:draw-arrow
  start-point
  end-point
  layer-name
  color-mode
  color-data
  text-height
  scale
)
```

Где:

```lisp
start-point = (x y)
end-point = (x y)
layer-name = "2 цикл"
color-mode = "BYLAYER" | "ACI" | "RGB"
color-data = 1 или (255 0 0)
text-height = 2.5
scale = 5.0
```

---

## 3.6. Математика стрелки

Исходные точки:

```lisp
p1 = (x1 y1)
p2 = (x2 y2)
```

Вектор:

```lisp
dx = x2 - x1
dy = y2 - y1
```

Исходная длина:

```lisp
len = distance(p1, p2)
```

Конечная точка линии с учётом масштаба:

```lisp
x3 = x1 + dx * scale
y3 = y1 + dy * scale
p3 = (x3 y3)
```

Угол:

```lisp
ang = angle(p1, p3)
```

Длина крыла:

```lisp
arrow_length = 0.2 * len * scale
```

Угол крыльев:

```lisp
10 градусов = (* 10.0 (/ pi 180.0))
```

Точки крыльев:

```lisp
w1 = polar(p3, ang + pi - 10°, arrow_length)
w2 = polar(p3, ang + pi + 10°, arrow_length)
```

То есть треугольник:

```text
p3, w1, w2
```

Для `AcDbSolid` нужно передать 4 точки, поэтому третью можно повторить:

```text
p3, w1, w2, w2
```

---

## 3.7. Пример функции отрисовки

Это каркасный пример, который можно отдать нейросети для доработки.

```lisp
(defun lcm:pt3 (p)
  (vlax-3d-point
    (list
      (float (car p))
      (float (cadr p))
      0.0
    )
  )
)

(defun lcm:deg2rad (d)
  (* d (/ pi 180.0))
)

(defun lcm:set-object-color (obj color-mode color-data / tc)
  (cond
    ;; ByLayer
    ((= color-mode "BYLAYER")
     (vla-put-Color obj 256)
    )

    ;; ACI
    ((= color-mode "ACI")
     (vla-put-Color obj (atoi (itoa color-data)))
    )

    ;; RGB
    ((= color-mode "RGB")
     (setq tc (vla-get-TrueColor obj))
     (vla-SetRGB
       tc
       (car color-data)
       (cadr color-data)
       (caddr color-data)
     )
     (vla-put-TrueColor obj tc)
    )
  )
)

(defun lcm:set-object-properties (obj layer-name color-mode color-data)
  (vla-put-Layer obj layer-name)
  (lcm:set-object-color obj color-mode color-data)
)

(defun lcm:draw-arrow
  (
    start-point
    end-point
    layer-name
    color-mode
    color-data
    text-height
    scale
    /
    acad doc ms
    x1 y1 x2 y2 dx dy len
    x3 y3 tip ang wing-len w1 w2
    line solid txt dist-mm
  )

  (setq x1 (car start-point))
  (setq y1 (cadr start-point))
  (setq x2 (car end-point))
  (setq y2 (cadr end-point))

  (setq dx (- x2 x1))
  (setq dy (- y2 y1))
  (setq len (distance start-point end-point))

  (if (or (zerop len) (<= scale 0.0))
    (progn
      (prompt "\nОшибка: нулевая длина или неверный масштаб.")
      nil
    )
    (progn
      (setq x3 (+ x1 (* dx scale)))
      (setq y3 (+ y1 (* dy scale)))
      (setq tip (list x3 y3))

      (setq ang (angle start-point tip))
      (setq wing-len (* 0.2 len scale))

      (setq w1
        (polar
          tip
          (+ ang pi (- (lcm:deg2rad 10.0)))
          wing-len
        )
      )

      (setq w2
        (polar
          tip
          (+ ang pi (lcm:deg2rad 10.0))
          wing-len
        )
      )

      (setq acad (vlax-get-acad-object))
      (setq doc (vla-get-ActiveDocument acad))
      (setq ms (vla-get-ModelSpace doc))

      ;; Линия
      (setq line
        (vla-AddLine
          ms
          (lcm:pt3 start-point)
          (lcm:pt3 tip)
        )
      )

      ;; Залитый треугольник
      (setq solid
        (vla-AddSolid
          ms
          (lcm:pt3 tip)
          (lcm:pt3 w1)
          (lcm:pt3 w2)
          (lcm:pt3 w2)
        )
      )

      ;; Текст длины
      (setq dist-mm (fix (+ (* len 1000.0) 0.5)))

      (setq txt
        (vla-AddText
          ms
          (itoa dist-mm)
          (lcm:pt3 tip)
          (float text-height)
        )
      )

      ;; Свойства
      (lcm:set-object-properties line layer-name color-mode color-data)
      (lcm:set-object-properties solid layer-name color-mode color-data)
      (lcm:set-object-properties txt layer-name color-mode color-data)

      line
    )
  )
)
```

---

## 3.8. Главная функция выполнения

Аналог Python:

```python
main_script(...)
```

На LISP:

```lisp
(defun lcm:run
  (
    layer-zero
    layer-last
    mappings
    scale
    color-mode
    color-data
    text-height
    /
    acad doc
    points-zero points-last
    count errors
  )

  (setq acad (vlax-get-acad-object))
  (setq doc (vla-get-ActiveDocument acad))

  (vla-StartUndoMark doc)

  (setq points-zero (lcm:get-points-with-names layer-zero))
  (setq points-last (lcm:get-points-with-names layer-last))

  (setq count 0)
  (setq errors 0)

  (foreach mapping mappings
    (setq from-name (cdr (assoc 'from mapping)))
    (setq to-name (cdr (assoc 'to mapping)))

    (setq start-pt (cdr (assoc from-name points-zero)))
    (setq end-pt (cdr (assoc to-name points-last)))

    (if (and start-pt end-pt)
      (progn
        (if (lcm:draw-arrow
              start-pt
              end-pt
              layer-last
              color-mode
              color-data
              text-height
              scale
            )
          (setq count (1+ count))
          (setq errors (1+ errors))
        )
      )
      (progn
        (prompt "\nНе найдены точки для сопоставления: ")
        (prompt from-name)
        (prompt " -> ")
        (prompt to-name)
        (setq errors (1+ errors))
      )
    )
  )

  (vla-EndUndoMark doc)

  (prompt "\nГотово. Построено стрелок: ")
  (prompt (itoa count))

  (if (> errors 0)
    (progn
      (prompt "\nОшибок: ")
      (prompt (itoa errors))
    )
  )

  (princ)
)
```

Формат `mappings` можно сделать таким:

```lisp
(setq mappings
  (list
    (list (cons 'from "1") (cons 'to "1"))
    (list (cons 'from "2") (cons 'to "5"))
  )
)
```

## Результат этапа

У тебя должен работать консольный вариант:

```lisp
(lcm:run
  "0 цикл"
  "2 цикл"
  (list
    (list (cons 'from "1") (cons 'to "1"))
  )
  5.0
  "ACI"
  1
  2.5
)
```

Если это работает — ядро перенесено.

---

# Этап 4. Сделать интерфейс на DCL

Теперь нужно повторить Tkinter-интерфейс средствами AutoCAD.

---

## 4.1. Ограничения DCL

Сразу важно понять:

DCL не умеет красиво и динамично создавать строки с combobox, как Tkinter.

Поэтому интерфейс сопоставлений лучше сделать так:

- есть `list_box`, где показываются строки:
  ```text
  1 -> 1
  2 -> 5
  3 -> не найдено
  ```
- кнопки:
  - `Добавить...`
  - `Изменить...`
  - `Удалить`
  - `Авто-сопоставление`
  - `Очистить`
- при нажатии `Добавить` или `Изменить` открывается второй маленький диалог с двумя `popup_list`.

Это нормальный нативный подход для AutoCAD.

---

## 4.2. Файл `lcm_ui.dcl`

Примерный каркас:

```dcl
// ============================================================
// Layer Cycle Manager DCL
// ============================================================

lcm_main_dlg : dialog {
  label = "Layer Cycle Manager";

  : boxed_column {
    label = "Выбор слоёв";

    : row {
      : text {
        label = "Нулевой цикл:";
        width = 18;
      }
      : popup_list {
        key = "layer_zero";
        width = 35;
      }
    }

    : row {
      : text {
        label = "Последний цикл:";
        width = 18;
      }
      : popup_list {
        key = "layer_last";
        width = 35;
      }
    }

    : row {
      : button {
        key = "refresh_layers";
        label = "Обновить слои";
      }
    }
  }

  : boxed_column {
    label = "Параметры стрелок";

    : row {
      : text {
        label = "Цвет:";
        width = 18;
      }
      : popup_list {
        key = "color_mode";
        width = 20;
      }
    }

    : row {
      : text {
        label = "ACI:";
        width = 18;
      }
      : edit_box {
        key = "aci";
        width = 10;
      }
      : button {
        key = "pick_aci";
        label = "Выбрать...";
      }
    }

    : row {
      : text {
        label = "RGB:";
        width = 18;
      }
      : edit_box {
        key = "rgb_r";
        width = 5;
      }
      : edit_box {
        key = "rgb_g";
        width = 5;
      }
      : edit_box {
        key = "rgb_b";
        width = 5;
      }
    }

    : row {
      : text {
        label = "Высота текста:";
        width = 18;
      }
      : edit_box {
        key = "text_height";
        width = 10;
      }
    }

    : row {
      : text {
        label = "Масштаб:";
        width = 18;
      }
      : edit_box {
        key = "scale";
        width = 10;
      }
    }
  }

  : boxed_column {
    label = "Сопоставление точек";

    : text {
      key = "info";
      label = "Выберите слои для загрузки точек";
    }

    : list_box {
      key = "mappings";
      width = 70;
      height = 8;
    }

    : row {
      : button {
        key = "add_mapping";
        label = "Добавить...";
      }
      : button {
        key = "edit_mapping";
        label = "Изменить...";
      }
      : button {
        key = "remove_mapping";
        label = "Удалить";
      }
    }

    : row {
      : button {
        key = "auto_mapping";
        label = "Авто-сопоставление";
      }
      : button {
        key = "clear_mappings";
        label = "Очистить все";
      }
    }
  }

  ok_cancel;
}
```

Отдельный диалог для редактирования одного сопоставления:

```dcl
lcm_mapping_dlg : dialog {
  label = "Сопоставление точек";

  : row {
    : text {
      label = "Точка нулевого слоя:";
      width = 25;
    }
    : popup_list {
      key = "map_from";
      width = 30;
    }
  }

  : row {
    : text {
      label = "Точка последнего слоя:";
      width = 25;
    }
    : popup_list {
      key = "map_to";
      width = 30;
    }
  }

  ok_cancel;
}
```

---

## 4.3. Логика `lcm_ui.lsp`

Основные переменные:

```lisp
(setq lcm:layers '())
(setq lcm:points-zero '())
(setq lcm:points-last '())
(setq lcm:mappings '())
```

Основные функции:

```lisp
(lcm:show-main-dialog)
(lcm:fill-layer-list)
(lcm:on-layer-change)
(lcm:refresh-points)
(lcm:fill-mapping-list)
(lcm:add-mapping)
(lcm:edit-mapping)
(lcm:remove-mapping)
(lcm:auto-mapping)
(lcm:clear-mappings)
(lcm:validate-and-run)
```

---

## 4.4. Пример открытия главного диалога

```lisp
(defun lcm:show-main-dialog (/ dcl-id result)
  (setq dcl-id (load_dialog "lcm_ui.dcl"))

  (if (< dcl-id 0)
    (progn
      (alert "Не найден файл lcm_ui.dcl")
      (exit)
    )
  )

  (if (not (new_dialog "lcm_main_dlg" dcl-id))
    (progn
      (alert "Не удалось открыть диалог lcm_main_dlg")
      (unload_dialog dcl-id)
      (exit)
    )
  )

  ;; Инициализация
  (lcm:fill-layer-list)
  (lcm:fill-color-mode-list)
  (lcm:load-settings-to-dialog)
  (lcm:refresh-points)
  (lcm:fill-mapping-list)

  ;; Действия
  (action_tile "layer_zero" "(lcm:on-layer-change)")
  (action_tile "layer_last" "(lcm:on-layer-change)")
  (action_tile "refresh_layers" "(lcm:fill-layer-list)")

  (action_tile "color_mode" "(lcm:on-color-mode-change)")
  (action_tile "pick_aci" "(lcm:pick-aci-color)")

  (action_tile "add_mapping" "(lcm:add-mapping)")
  (action_tile "edit_mapping" "(lcm:edit-mapping)")
  (action_tile "remove_mapping" "(lcm:remove-mapping)")
  (action_tile "auto_mapping" "(lcm:auto-mapping)")
  (action_tile "clear_mappings" "(lcm:clear-mappings)")

  (action_tile "accept" "(lcm:validate-and-accept)")
  (action_tile "cancel" "(done_dialog 0)")

  (setq result (start_dialog))

  (unload_dialog dcl-id)

  (if (= result 1)
    (lcm:run-from-dialog)
  )

  (princ)
)
```

---

## 4.5. Заполнение popup-списков

Для слоёв:

```lisp
(defun lcm:fill-layer-list (/ layers)
  (setq layers (lcm:get-layers))
  (setq lcm:layers layers)

  (start_list "layer_zero")
  (foreach layer layers
    (add_list layer)
  )
  (end_list)

  (start_list "layer_last")
  (foreach layer layers
    (add_list layer)
  )
  (end_list)
)
```

Для списка сопоставлений:

```lisp
(defun lcm:fill-mapping-list (/ display)
  (start_list "mappings")

  (foreach mapping lcm:mappings
    (setq display
      (strcat
        (cdr (assoc 'from mapping))
        " -> "
        (cdr (assoc 'to mapping))
      )
    )
    (add_list display)
  )

  (end_list)
)
```

---

## 4.6. Авто-сопоставление

Логика:

```lisp
(defun lcm:auto-mapping (/ names-zero names-last new-mappings to-name)
  (setq new-mappings '())

  (setq names-zero
    (lcm:sort-names
      (mapcar 'car lcm:points-zero)
    )
  )

  (setq names-last
    (mapcar 'car lcm:points-last)
  )

  (foreach name names-zero
    (if (member name names-last)
      (setq to-name name)
      (setq to-name "не найдено")
    )

    (setq new-mappings
      (append
        new-mappings
        (list
          (list
            (cons 'from name)
            (cons 'to to-name)
          )
        )
      )
    )
  )

  (setq lcm:mappings new-mappings)

  (lcm:fill-mapping-list)
)
```

При выполнении нужно пропускать записи:

```lisp
(to = "не найдено")
```

---

## 4.7. Ручное добавление сопоставления

Отдельный диалог `lcm_mapping_dlg`:

```lisp
(defun lcm:add-mapping (/ dcl-id result from to)
  (setq dcl-id (load_dialog "lcm_ui.dcl"))

  (if (< dcl-id 0)
    (progn
      (alert "Не найден lcm_ui.dcl")
      (exit)
    )
  )

  (if (not (new_dialog "lcm_mapping_dlg" dcl-id))
    (progn
      (unload_dialog dcl-id)
      (exit)
    )
  )

  (lcm:fill-mapping-combos)

  (action_tile "accept" "(done_dialog 1)")
  (action_tile "cancel" "(done_dialog 0)")

  (setq result (start_dialog))

  (if (= result 1)
    (progn
      (setq from (get_tile "map_from"))
      (setq to (get_tile "map_to"))

      (if (and (/= from "") (/= to ""))
        (setq lcm:mappings
          (append
            lcm:mappings
            (list
              (list
                (cons 'from from)
                (cons 'to to)
              )
            )
          )
        )
      )

      (lcm:fill-mapping-list)
    )
  )

  (unload_dialog dcl-id)
)
```

---

## 4.8. Выбор цвета ACI

Для ACI можно использовать стандартный диалог:

```lisp
(defun lcm:pick-aci-color (/ current-color new-color)
  (setq current-color (atoi (get_tile "aci")))

  (if (or (< current-color 1) (> current-color 255))
    (setq current-color 1)
  )

  (setq new-color (acad_colordlg current-color))

  (if new-color
    (set_tile "aci" (itoa new-color))
  )
)
```

Важно:

> `acad_colordlg` обычно возвращает ACI.  
> Для полноценного RGB-диалога в чистом AutoLISP возможности зависят от версии AutoCAD.  
> Поэтому RGB лучше сделать ручным вводом R/G/B, а цветовой круг оставить для ACI.

Если нужен полноценный RGB-picker — это уже аргумент в пользу Plan B: C# + WPF.

---

## 4.9. Валидация перед OK

Проверить:

```lisp
- layer_zero не пустой
- layer_last не пустой
- scale > 0
- text_height > 0
- color_mode корректный
- если ACI: 1..255
- если RGB: 0..255 каждый канал
- есть хотя бы одно валидное сопоставление
- нет сопоставлений со значением "не найдено"
```

Пример:

```lisp
(defun lcm:validate-and-accept (/ layer-zero layer-last scale text-height color-mode aci r g b)
  (setq layer-zero (get_tile "layer_zero"))
  (setq layer-last (get_tile "layer_last"))

  (if (or (= layer-zero "") (= layer-last ""))
    (progn
      (alert "Выберите оба слоя.")
      (exit)
    )
  )

  (setq scale (atof (get_tile "scale")))
  (if (<= scale 0.0)
    (progn
      (alert "Масштаб должен быть больше нуля.")
      (exit)
    )
  )

  (setq text-height (atof (get_tile "text_height")))
  (if (<= text-height 0.0)
    (progn
      (alert "Высота текста должна быть больше нуля.")
      (exit)
    )
  )

  ;; Далее проверка цвета в зависимости от color_mode
  ;; ...

  (lcm:save-settings-from-dialog)

  (done_dialog 1)
)
```

---

## Результат этапа

У тебя должен быть рабочий диалог:

- выбор слоёв;
- обновление точек;
- авто-сопоставление;
- ручное добавление;
- удаление;
- очистка;
- ACI;
- RGB вручную;
- ByLayer;
- высота текста;
- масштаб;
- OK запускает отрисовку.

---

# Этап 5. Интеграция в интерфейс AutoCAD через CUIX

Теперь нужно сделать кнопку, как у menuGEO.

---

## 5.1. Открыть редактор CUI

В AutoCAD:

```text
CUI
```

или:

```text
_CUI
```

---

## 5.2. Создать новый partial CUIX

В редакторе CUI:

1. Выбрать `Customize` → `All Customization Files`.
2. Нажать правой кнопкой мыши на `Partial Customization Files`.
3. Выбрать `Load Customization File` или создать новый.
4. Сохранить как:

```text
lcm.cuix
```

Лучше хранить его в папке проекта:

```text
LayerCycleManager/lcm.cuix
```

---

## 5.3. Создать команду

В CUI editor:

1. Найти `Command List`.
2. Создать новую команду.
3. Имя:

```text
LCM_Start
```

4. Display name:

```text
Layer Cycle Manager
```

5. Description:

```text
Построение стрелок между точками разных циклов
```

6. Macro:

```text
^C^C^P(if (not (fboundp 'lcm:start))(load "lcm_main.lsp"));_LCM;
```

Разбор макроса:

```text
^C^C
```

отменяет текущую команду;

```text
^P(...)
```

выполняет LISP-выражение;

```lisp
(if (not (fboundp 'lcm:start))(load "lcm_main.lsp"))
```

подгружает программу, если она ещё не загружена;

```text
_LCM;
```

запускает команду `LCM`.

---

## 5.4. Создать вкладку и панель

В CUI:

1. Создать новую Ribbon Tab:
   ```text
   Layer Cycle Manager
   ```

2. Создать Ribbon Panel:
   ```text
   Стрелки
   ```

3. Перетащить команду `LCM_Start` на панель.

---

## 5.5. Добавить иконки

Подготовь:

```text
icons/lcm_16.bmp
icons/lcm_32.bmp
```

Рекомендуемые размеры:

```text
16x16
32x32
```

Формат:

```text
BMP
```

PNG иногда поддерживается, но BMP надёжнее для старых CUIX.

Назначь иконки команде:

- Small Image;
- Large Image.

---

## 5.6. Сохранить CUIX

Сохрани:

```text
lcm.cuix
```

Убедись, что это partial CUIX, а не основной `acad.cuix`.

---

## Результат этапа

- есть `lcm.cuix`;
- есть команда;
- есть кнопка;
- макрос подгружает LISP.

---

# Этап 6. Первая загрузка в AutoCAD

## 6.1. Проверить Support Path

Папка `LayerCycleManager` должна быть в:

```text
OPTIONS → Files → Support File Search Path
```

И желательно в:

```text
OPTIONS → Files → Trusted Locations
```

## 6.2. Загрузить CUIX

Выполни:

```text
_MENULOAD
```

Выбери:

```text
lcm.cuix
```

Нажми `Load`.

## 6.3. Проверить Ribbon

Должна появиться вкладка:

```text
Layer Cycle Manager
```

Если её нет:

- правый клик по Ribbon;
- включить вкладку;
- проверить через `CUI`;
- выполнить `CUILOAD` / `MENULOAD` повторно.

## 6.4. Нажать кнопку

При нажатии:

1. AutoCAD выполнит макрос.
2. Подгрузится `lcm_main.lsp`.
3. Запустится команда `LCM`.
4. Откроется DCL-диалог.

---

# Этап 7. Настройка загрузки LISP и путей

Это один из самых важных моментов.

---

## 7.1. Если папка добавлена в Support Path

Тогда в CUIX-макросе можно писать просто:

```lisp
(load "lcm_main.lsp")
```

AutoCAD сам найдёт файл.

Это лучший вариант.

---

## 7.2. Если не хочешь зависеть от Support Path

Тогда нужен loader.

Файл:

```text
loader/lcm_loader.lsp
```

Примерная логика:

```lisp
(defun C:LCMLOAD (/ file path)
  (setq file
    (getfiled
      "Выберите lcm_main.lsp в папке LayerCycleManager"
      ""
      "lsp"
      0
    )
  )

  (if (not file)
    (progn
      (prompt "\nЗагрузка отменена.")
      (princ)
      (exit)
    )
  )

  (setq path (vl-filename-directory file))

  ;; Сохранить путь, например, в переменную окружения
  (setenv "LCM_PATH" path)

  ;; Загрузить основной файл
  (load (strcat path "/lcm_main.lsp"))

  ;; Загрузить CUIX
  (command "_.menuload" (strcat path "/lcm.cuix"))

  (prompt "\nLayer Cycle Manager загружен.")
  (princ)
)
```

Пользователь:

```text
APPLOAD → lcm_loader.lsp
LCMLOAD
```

Дальше всё загружается.

---

## 7.3. Где хранить путь

Варианты:

### Вариант 1. Environment variable

```lisp
(setenv "LCM_PATH" path)
```

Плюс: просто.

Минус: это уже не полностью файловая автономность.

### Вариант 2. Текстовый файл в `%APPDATA%`

Например:

```text
%APPDATA%/LayerCycleManager/path.cfg
```

Плюс: можно читать/писать из LISP.

Минус: файл вне папки программы.

### Вариант 3. Support Path

Самый чистый.

Минус: пользователь один раз добавляет папку.

---

## Моя рекомендация

Для конечных пользователей:

```text
Support Path + _menuload
```

Для продвинутой установки:

```text
LCMLOAD как запасной вариант
```

---

# Этап 8. Настройки программы

Сделай файл настроек:

```text
settings/lcm_settings.cfg
```

Формат можно сделать простым LISP-списком:

```lisp
(
  ("LAYER_ZERO" . "0 цикл")
  ("LAYER_LAST" . "2 цикл")
  ("COLOR_MODE" . "ACI")
  ("ACI" . 1)
  ("RGB_R" . 255)
  ("RGB_G" . 0)
  ("RGB_B" . 0)
  ("TEXT_HEIGHT" . 2.5)
  ("SCALE" . 5.0)
  ("TEXT_SEARCH_RADIUS" . 50.0)
  ("UNIT_TO_MM" . 1000.0)
)
```

Чтение:

```lisp
(defun lcm:read-settings (/ file data)
  (setq file (findfile "settings/lcm_settings.cfg"))

  (if file
    (progn
      (setq data (open file "r"))
      (if data
        (progn
          (setq lcm:settings (read data))
          (close data)
        )
      )
    )
  )
)
```

Запись:

```lisp
(defun lcm:write-settings (/ file out)
  (setq file "settings/lcm_settings.cfg")
  (setq out (open file "w"))

  (if out
    (progn
      (prin1 lcm:settings out)
      (close out)
    )
  )
)
```

В продакшене лучше использовать абсолютный путь к папке настроек, чтобы не зависеть от текущей директории DWG.

---

# Этап 9. Тестирование

## 9.1. Функциональные тесты

Проверь:

### Слои

- список слоёв заполняется;
- кнопка `Обновить слои` работает;
- при смене слоя обновляются точки;
- если на слое нет точек, показывается 0.

### Точки

- точки читаются;
- тексты читаются;
- ближайший текст находится;
- если текста нет, создаётся имя `Точка_<Handle>`;
- числовые имена сортируются правильно:
  ```text
  1, 2, 10, 11
  ```
  а не:
  ```text
  1, 10, 11, 2
  ```

### Сопоставления

- авто-сопоставление создаёт пары;
- если имя не найдено, показывается `не найдено`;
- ручное добавление работает;
- редактирование работает;
- удаление работает;
- очистка работает;
- невалидные пары не запускаются.

### Отрисовка

- линия рисуется в правильном направлении;
- масштаб работает;
- длина подписывается по исходным точкам;
- длина в мм;
- наконечник смотрит в нужную сторону;
- треугольник залит;
- текст находится в острие;
- объекты на нужном слое;
- цвет ByLayer работает;
- ACI работает;
- RGB работает.

### Undo

Проверь:

```text
Ctrl+Z
```

Все созданные объекты должны удаляться за один undo, если использовать:

```lisp
(vla-StartUndoMark doc)
...
(vla-EndUndoMark doc)
```

---

## 9.2. Тесты безопасности

Проверь:

- нет точек на слое;
- нет текстов;
- точки с одинаковыми именами;
- пустые сопоставления;
- масштаб = 0;
- масштаб отрицательный;
- высота текста = 0;
- ACI = 0;
- ACI = 300;
- RGB = 300;
- слой заблокирован;
- слой заморожен;
- чертёж без сохранённого пути;
- русские имена слоёв;
- длинные имена слоёв.

---

## 9.3. Отладка

Используй:

```lisp
(prompt "\nDebug: ...")
(prin1 variable)
```

В VLIDE можно смотреть переменные и трассировать.

Для ошибок:

```lisp
(vl-catch-all-apply ...)
(vl-catch-all-error-p ...)
(vl-catch-all-error-message ...)
```

---

# Этап 10. Упаковка и установка на другой компьютер

## 10.1. Финальная папка

```text
LayerCycleManager/
│
├── lcm_main.lsp
├── lcm_config.lsp
├── lcm_data.lsp
├── lcm_core.lsp
├── lcm_ui.lsp
├── lcm_ui.dcl
├── lcm.cuix
│
├── icons/
│   ├── lcm_16.bmp
│   └── lcm_32.bmp
│
├── settings/
│
├── loader/
│   └── lcm_loader.lsp
│
├── README.txt
└── install_notes.txt
```

---

## 10.2. README для пользователя

Пример:

```text
Установка Layer Cycle Manager

1. Скопируйте папку LayerCycleManager на компьютер.
   Например:
   C:\Tools\LayerCycleManager

2. Откройте AutoCAD.

3. Добавьте папку в Support File Search Path:
   OPTIONS → Files → Support File Search Path → Add

4. Добавьте папку в Trusted Locations, если AutoCAD требует доверие.

5. Выполните команду:
   _MENULOAD

6. Загрузите файл:
   LayerCycleManager\lcm.cuix

7. На ленте появится вкладка Layer Cycle Manager.

8. Нажмите кнопку Layer Cycle Manager или введите команду:
   LCM
```

---

## 10.3. Обновление программы

Если обновляешь CUIX:

```text
CUIUNLOAD → выбрать lcm.cuix
заменить файлы
_MENULOAD → lcm.cuix
```

Или просто закрыть AutoCAD, заменить файлы, открыть снова.

---

# Этап 11. Опциональная компиляция в FAS / VLX

Если хочешь защитить код:

## 11.1. Открыть VLIDE

В AutoCAD:

```text
VLIDE
```

## 11.2. Compile

```text
Tools → Compile
```

Можно компилировать `.lsp` в `.fas`.

Можно собрать проект в `.vlx`.

## 11.3. Особенности

- DCL часто проще оставить отдельным файлом.
- VLX может быть удобен для распространения.
- Но отладка исходников проще.

Моя рекомендация:

- разрабатывать в `.lsp`;
- релиз можно собрать в `.fas` или `.vlx`;
- DCL оставить рядом, если не получится надёжно упаковать его внутрь VLX.

---

# Этап 12. Plan B: если DCL не устроит

Если в процессе окажется, что DCL слишком неудобен, можно переделать интерфейс на C# + WPF.

Но ядро можно оставить тем же по смыслу.

## Когда выбирать .NET

Тебе нужен .NET, если хочешь:

- таблицу сопоставлений с выпадающими списками прямо в строках;
- современный UI;
- полноценный RGB color picker;
- предпросмотр стрелки;
- сложные настройки;
- нормальную привязку данных;
- resizable-окна без боли.

## Стек Plan B

| Компонент | Технология |
|---|---|
| Язык | C# |
| API | AutoCAD.NET |
| UI | WPF |
| Сборка | .dll |
| Загрузка | `NETLOAD` или autoload bundle |
| Интерфейс | CUIX-кнопка вызывает команду |

## Пример команды на C#

```csharp
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.Runtime;

namespace LayerCycleManager
{
    public class Commands
    {
        [CommandMethod("LCM")]
        public void StartLcm()
        {
            // Открыть WPF-окно
        }
    }
}
```

## Особенности

Нужны ссылки на DLL AutoCAD:

```text
accoremgd.dll
acdbmgd.dll
acmgd.dll
```

Они лежат в папке AutoCAD.

Важно:

- `Copy Local = false`;
- версия .NET Framework должна соответствовать AutoCAD;
- под каждую крупную версию AutoCAD часто нужно пересобирать;
- загрузка DLL через `NETLOAD`;
- CUIX-кнопка может вызывать команду `LCM`.

## CUIX macro для .NET

Если DLL уже загружена:

```text
^C^C_LCM;
```

Если нужно подгружать DLL:

```text
^C^C^P(command "._NETLOAD" "C:/Tools/LayerCycleManager/LayerCycleManager.dll");_LCM;
```

Но абсолютный путь — плохо для переносимости.

Поэтому для .NET чаще делают:

- autoload bundle;
- `PackageContents.xml`;
- installer;
- или support path + loader.

---

# 13. Как использовать нейросети для разработки

Ты говорил, что планируешь писать код с помощью ИИ. Здесь важна правильная нарезка задач.

Не проси сразу:

> Напиши мне весь плагин для AutoCAD.

Лучше разбивать по модулям.

---

## 13.1. Промпт для переноса получения точек

Пример:

```text
Ты — эксперт по AutoLISP / Visual LISP и AutoCAD ActiveX.

У меня есть Python-функция для pyautocad:

[вставить get_points_with_names]

Перепиши её на Visual LISP.

Требования:
- использовать vlax-get-acad-object;
- перебирать объекты ModelSpace;
- искать AcDbPoint, AcDbText, AcDbMText;
- учитывать слой;
- для каждой точки искать ближайший текст в радиусе 50;
- если текст не найден, имя = "Точка_" + Handle;
- вернуть association list: ((name . (x y)) ...);
- добавить обработку ошибок через vl-catch-all-apply;
- использовать локальные переменные;
- в конце princ.
```

---

## 13.2. Промпт для отрисовки стрелки

```text
Ты — эксперт по AutoLISP / Visual LISP.

Нужно написать функцию lcm:draw-arrow.

Вход:
start-point = (x y)
end-point = (x y)
layer-name = string
color-mode = "BYLAYER" | "ACI" | "RGB"
color-data = integer для ACI или list (r g b) для RGB
text-height = real
scale = real

Логика:
- линия рисуется от start до start + (end-start)*scale;
- длина подписывается по исходным точкам;
- длина в мм = round(length * 1000);
- наконечник: залитый AcDbSolid;
- угол при вершине 20 градусов;
- длина крыла = 0.2 * length * scale;
- текст размещается в точке острия;
- использовать vla-AddLine, vla-AddSolid, vla-AddText;
- поддержка цвета ByLayer, ACI, RGB через TrueColor;
- обработка ошибок.
```

---

## 13.3. Промпт для DCL

```text
Ты — эксперт по AutoCAD DCL.

Нужно написать DCL-файл для плагина Layer Cycle Manager.

Главный диалог должен содержать:
- выбор нулевого слоя через popup_list;
- выбор последнего слоя через popup_list;
- кнопку обновить слои;
- выбор режима цвета: ACI, RGB, ByLayer;
- поле ACI;
- кнопку выбрать ACI;
- три поля RGB;
- поле высоты текста;
- поле масштаба;
- list_box для сопоставлений точек;
- кнопки добавить, изменить, удалить, авто, очистить;
- OK/Cancel.

Также нужен отдельный диалог для добавления/изменения одного сопоставления:
- popup_list для точки из нулевого слоя;
- popup_list для точки из последнего слоя;
- OK/Cancel.

Напиши полный DCL-код.
```

---

## 13.4. Промпт для CUIX

```text
Опиши пошагово, как в AutoCAD CUI editor создать partial CUIX файл lcm.cuix:
- новая команда LCM_Start;
- macro ^C^C^P(if (not (fboundp 'lcm:start))(load "lcm_main.lsp"));_LCM;
- новая ribbon tab;
- новая panel;
- кнопка с иконками 16x16 и 32x32;
- сохранение partial cuix;
- загрузка через _menuload.
```

---

# 14. Итоговый пошаговый маршрут

Если коротко, делай так:

## Шаг 1. Подготовка

- AutoCAD полный.
- VSCode.
- Создать папку `LayerCycleManager`.
- Создать тестовый DWG.
- Добавить папку в Support Path и Trusted Locations.

## Шаг 2. Каркас

- Написать `lcm_main.lsp`.
- Сделать команду `LCM`.
- Проверить запуск.

## Шаг 3. Данные

- Написать `lcm:get-layers`.
- Написать `lcm:get-points-with-names`.
- Проверить чтение точек и текстов.
- Проверить сортировку имён.

## Шаг 4. Ядро отрисовки

- Написать `lcm:draw-arrow`.
- Проверить линию.
- Проверить solid.
- Проверить текст.
- Проверить цвет ByLayer / ACI / RGB.
- Проверить масштаб.

## Шаг 5. Консольный прогон

- Написать `lcm:run`.
- Запустить вручную из командной строки.
- Убедиться, что стрелки строятся без GUI.

## Шаг 6. DCL

- Написать `lcm_ui.dcl`.
- Написать `lcm_ui.lsp`.
- Сделать выбор слоёв.
- Сделать список точек.
- сделать сопоставления.
- сделать авто-сопоставление.
- сделать ручное редактирование.
- сделать валидацию.

## Шаг 7. Связка GUI и ядра

- OK в диалоге вызывает `lcm:run`.
- Настройки сохраняются.
- Ошибки показываются через `alert` или prompt.

## Шаг 8. CUIX

- Создать `lcm.cuix`.
- Создать команду `LCM_Start`.
- Назначить макрос.
- Создать вкладку и панель.
- Добавить иконки.

## Шаг 9. Установка

- Проверить `_menuload`.
- Проверить кнопку.
- Проверить на чистом профиле AutoCAD.
- Проверить на другом компьютере.

## Шаг 10. Релиз

- Написать README.
- Опционально скомпилировать LSP в FAS/VLX.
- Сделать ZIP-архив.
- Сделать инструкцию установки.

---

# 15. Критерии готовности программы

Программа готова, если:

1. Папку можно скопировать на другой компьютер.
2. В AutoCAD достаточно добавить папку в Support Path.
3. `_menuload` загружает `lcm.cuix`.
4. Появляется кнопка.
5. Кнопка открывает нативный диалог AutoCAD.
6. Можно выбрать два слоя.
7. Можно задать:
   - цвет ByLayer;
   - цвет ACI;
   - цвет RGB;
   - высоту текста;
   - масштаб.
8. Можно сделать авто-сопоставление.
9. Можно вручную сопоставить точки с разными именами.
10. Можно удалить и очистить сопоставления.
11. Стрелки строятся корректно.
12. Длина подписывается в мм.
13. `Ctrl+Z` отменяет весь набор стрелок.
14. Нет зависимостей от Python, pip, pyautocad, ezdxf.
15. Программа работает после перезапуска AutoCAD.

---

# 16. Моя итоговая рекомендация

Для твоей задачи я бы делал так:

```text
AutoLISP / Visual LISP
+
DCL
+
Partial CUIX
+
Support Path
+
_MENULOAD
```

Это даст:

- нативность;
- portability;
- menuGEO-подобную установку;
- отсутствие Python;
- простую поддержку;
- возможность сгенерировать код нейросетями по частям.

А уже если DCL окажется слишком неудобным, переходить на:

```text
C# + AutoCAD.NET + WPF
```

Но я бы рассматривал это как вторую итерацию, когда логика уже отлажена и понятно, чего не хватает в интерфейсе.