#ifndef Telegram_NetworkLogging_h
#define Telegram_NetworkLogging_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void NetworkRegisterLoggingFunction();
void NetworkSetLoggingEnabled(bool);
void NetworkLog(NSString *domain, NSString *message);

void setBridgingTraceFunction(void (*function)(NSString * _Nullable, NSString * _Nullable));
void setBridgingShortTraceFunction(void (*function)(NSString * _Nullable, NSString * _Nullable));

NS_ASSUME_NONNULL_END

#endif
