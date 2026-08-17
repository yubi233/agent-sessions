package httpapi

import "context"

// publishPersistedSessionEvents 在业务事务提交后投递 Hub。SQLite 读取失败或慢订阅者
// 丢弃都不能反向改变已经提交的 HTTP 写操作；客户端必须把账号 cursor 回放视为事实源。
func (a *API) publishPersistedSessionEvents(ctx context.Context, accountID, sessionID string, afterEventSeq int64) {
	if a.Events == nil || sessionID == "" || afterEventSeq < 0 {
		return
	}
	events, err := a.Repo.ListEventsAfter(ctx, sessionID, afterEventSeq)
	if err != nil {
		return
	}
	for _, event := range events {
		a.Events.Publish(sessionID, event)
		a.Events.PublishAccount(accountID, event)
	}
}

// publishLatestSessionEvent 是 delegation 事务的尽力投影。delegation 服务会在 parent
// session 上同步推进 last_seq，因此这里只取该 parent 的最新已提交事件通知订阅者。
func (a *API) publishLatestSessionEvent(ctx context.Context, accountID, sessionID string) {
	session, err := a.Sessions.GetSession(ctx, sessionID)
	if err != nil || session.AccountID != accountID || session.LastSeq <= 0 {
		return
	}
	a.publishPersistedSessionEvents(ctx, accountID, sessionID, session.LastSeq-1)
}
