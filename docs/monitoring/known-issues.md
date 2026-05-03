# Known issues

- 2026-05-03: lab-network.sh rollback оставляет VM-tap-интерфейсы
  висеть на старом bridge. Workaround: после rollback/apply сделать
  qm stop+start всех VM на bridge.

- 2026-05-03: clipboard на ноуте мутирует имена файлов при копировании
  из чата Claude в Markdown-ссылки. Блокирует heredoc-вставку
  скриптов. Найти и выключить расширение/менеджер на ноуте.
