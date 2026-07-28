#ifndef Telegram_NetworkLogging_h
#define Telegram_NetworkLogging_h

#import <Foundation/Foundation.h>

void NetworkRegisterLoggingFunction();
void NetworkSetLoggingEnabled(bool);
void NetworkLog(NSString * _Nonnull domain, NSString * _Nonnull message);

void setBridgingTraceFunction(void (*)(NSString *, NSString *));
void setBridgingShortTraceFunction(void (*)(NSString *, NSString *));

#endif
