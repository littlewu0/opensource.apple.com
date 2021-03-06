/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

/*
 * Controller.m
 *
 * Controller for lookupd
 * 
 * Copyright (c) 1995, NeXT Computer Inc.
 * All rights reserved.
 * Written by Marc Majka
 */

#import <NetInfo/config.h>
#import <NetInfo/system_log.h>
#import <NetInfo/project_version.h>
#import "Controller.h"
#import "Thread.h"
#import "LUPrivate.h"
#import "LUCachedDictionary.h"
#import "Config.h"
#import "LUGlobal.h"
#import "MachRPC.h"
#import "LUServer.h"
#import "CacheAgent.h"
#import "DNSAgent.h"
#import "NILAgent.h"
#import <NetInfo/dsutil.h>
#import "sys.h"
#import <sys/types.h>
#import <sys/param.h>
#import <unistd.h>
#import <string.h>
#import <libc.h>
#import <netdb.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <ifaddrs.h>

#define forever for(;;)

extern sys_port_type server_port;
extern sys_port_type _lookupd_port(sys_port_type);
extern int _lookup_link();

@implementation Controller

/*
 * Server runs in this loop to answer requests
 */
- (void)serverLoop
{
	kern_return_t status;
	lookup_request_msg *request;
	Thread *t, *x;

	t = [Thread currentThread];

	forever
	{
		/* Receive and service a request */
		[t setState:ThreadStateIdle];
		request = (lookup_request_msg *)calloc(1, sizeof(lookup_request_msg));
		status = sys_receive_message(&request->head, sizeof(lookup_request_msg), server_port, 0);
		[t setState:ThreadStateActive];

		if (shutting_down) break;
		if (status != KERN_SUCCESS)
		{
			system_log(LOG_NOTICE, "Server status = %s (%d)", sys_strerror(status), status);
			continue;
		}

		syslock_lock(threadCountLock);
		idleThreads--;
		if ((idleThreads == 0) && (threadCount < maxThreads))
		{
			x = [[Thread alloc] init];
			[x setName:"IPC Server"];
			[x shouldTerminate:YES];
			[x run:@selector(serverLoop) context:self];
			threadCount++;
			idleThreads++;
		}
		syslock_unlock(threadCountLock);

		/* request is owned by the thread, which needs to free it when done */
		[t setData:(void *)request];
		[machRPC process];

		/* check idle threads */
		syslock_lock(threadCountLock);
		idleThreads++;
		if ((idleThreads > maxIdleThreads) && ([t shouldTerminate]))
		{
			idleThreads--;
			threadCount--;
			syslock_unlock(threadCountLock);
			system_log(LOG_DEBUG, "serverloop terminated thread (%d idle, max %d)", idleThreads, maxIdleThreads);
			[t terminateSelf];
		}
		syslock_unlock(threadCountLock);

		if (shutting_down) break;
	}
}

- (void)newAgent:(id)agent name:(char *)name
{
	if (agentCount == 0) agents = (id *)malloc(sizeof(id));
	else agents = (id *)realloc(agents, (agentCount + 1) * sizeof(id));
	agents[agentCount] = agent;
	agentNames = appendString(name, agentNames);
	agentCount++;
}

- (id)agentClassNamed:(char *)name
{
	int status;
	unsigned int i;
	char *cname;

	i = listIndex(name, agentNames);
	if (i != IndexNull) return agents[i];

	status = asprintf(&cname, "%sAgent", name);
	if (status < 0) return nil;

	i = listIndex(cname, agentNames);
	free(cname);
	if (i != IndexNull) return agents[i];

	return nil;
}

- (void)initConfig
{
	LUArray *configurationArray;
	LUDictionary *global;
	char *logFileName;
	char *logFacilityName;
	FILE *fp;
	int pri, status;
	time_t now;
	char *str;

	configurationArray = [configManager config];
	global = [configManager configGlobal:configurationArray];

	debug_enabled = [configManager boolForKey:"Debug" dict:global default:debug_enabled];
	trace_enabled = [configManager boolForKey:"Trace" dict:global default:trace_enabled];

	aaaa_cutoff_enabled = [configManager boolForKey:"AAAACutoff" dict:global default:aaaa_cutoff_enabled];

	str = [configManager stringForKey:"GAISearch" dict:global default:NULL];
	if (str != NULL)
	{
		if (!strcasecmp(str, "Parallel")) gai_pref = GAI_P;
		else if (!strcasecmp(str, "Default")) gai_pref = GAI_P;
		else if (!strcasecmp(str, "P")) gai_pref = GAI_P;
		else if (!strcasecmp(str, "IPv4")) gai_pref = GAI_4;
		else if (!strcasecmp(str, "4")) gai_pref = GAI_4;
		else if (!strcasecmp(str, "IPv6")) gai_pref = GAI_6;
		else if (!strcasecmp(str, "6")) gai_pref = GAI_6;
		else if (!strcasecmp(str, "Serial")) gai_pref = GAI_S46;
		else if (!strcasecmp(str, "Serial46")) gai_pref = GAI_S46;
		else if (!strcasecmp(str, "46")) gai_pref = GAI_S46;
		else if (!strcasecmp(str, "Serial64")) gai_pref = GAI_S64;
		else if (!strcasecmp(str, "64")) gai_pref = GAI_S64;
		free(str);
	}

	gai_wait = [configManager intForKey:"GAIWait" dict:global default:gai_wait];

	if (debug_enabled)
	{
		statistics_enabled = YES;
		coredump_enabled = YES;
		system_log_set_max_priority(LOG_DEBUG);
	}
	else
	{
		statistics_enabled = [configManager boolForKey:"StatisticsEnabled" dict:global default:statistics_enabled];
		coredump_enabled = [configManager boolForKey:"CoreDumpEnabled" dict:global default:coredump_enabled];
	}

	logFileName = [configManager stringForKey:"LogFile" dict:global default:NULL];
	fp = fopen(logFileName, "a");
 	system_log_set_logfile(fp);
	freeString(logFileName);

	logFacilityName = [configManager stringForKey:"LogFacility" dict:global default:"LOG_NETINFO"];
	freeString(logFacilityName);

	now = time(0);
	status = asprintf(&str, "lookupd (version %s) starting - %s", _PROJECT_VERSION_, ctime(&now));
	if (status >= 0)
	{
		/* remove ctime trailing newline */
		str[strlen(str) - 1] = '\0';
		system_log(LOG_NOTICE, str);
		free(str);
	}

	maxThreads = [configManager intForKey:"MaxThreads" dict:global default:64];
	maxIdleThreads = [configManager intForKey:"MaxIdleThreads" dict:global default:2];
	maxIdleServers = [configManager intForKey:"MaxIdleServers" dict:global default:16];

	pri = [configManager intForKey:"LogPriority" dict:global default:system_log_max_priority()];
	system_log_set_max_priority(pri);

	[configurationArray release];
}

- (void)initNetAddrList
{
	struct ifaddrs *ifa, *ifap;
	sa_family_t family;
	struct sockaddr_in6 *sin6;
	struct sockaddr_in *sin4;
	char buf[128];
	BOOL isLinkLocal, isSiteLocal, isLoopback;

	if (getifaddrs(&ifa) != 0) return;

	for (ifap = ifa; ifap != NULL; ifap = ifap->ifa_next)
	{
		family = ifap->ifa_addr->sa_family;
		if (family != AF_INET && family != AF_INET6) continue;
		if (family == AF_INET6)
		{
			sin6 = (struct sockaddr_in6 *)(ifap->ifa_addr);
			isLinkLocal = (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr) != 0);
			isSiteLocal = (IN6_IS_ADDR_SITELOCAL(&sin6->sin6_addr) != 0);
			isLoopback = (IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr) != 0);

			if (isLinkLocal || isSiteLocal)
			{
				sin6->sin6_scope_id = ntohs(*(u_int16_t *)&sin6->sin6_addr.s6_addr[2]);
				sin6->sin6_addr.s6_addr[2] = 0;
				sin6->sin6_addr.s6_addr[3] = 0;
			}

			/*
			 * Anything other than link-local or loopback is considered routable.
			 * If we have routable IPv6 addresees, we want to do AAAA queries in DNS.
			 */
			if ((!isLinkLocal) && (!isLoopback)) aaaa_cutoff_enabled = NO;
		}

		if (family == AF_INET)
		{
			sin4 = (struct sockaddr_in *)(ifap->ifa_addr);
			if (inet_ntop(AF_INET, (void *)&(sin4->sin_addr), buf, sizeof(buf)) == NULL) continue;
		}
		else
		{
			sin6 = (struct sockaddr_in6 *)(ifap->ifa_addr);
			if (inet_ntop(AF_INET6, (void *)&(sin6->sin6_addr), buf, sizeof(buf)) == NULL) continue;
		}

		netAddrList = appendString(buf, netAddrList);
	}

	freeifaddrs(ifa);
}

- (id)initWithName:(char *)name
{
	DNSAgent *dns;

	[super init];

	dnsSearchList = NULL;
	netAddrList = NULL;

	controller = self;

 	if (name == NULL) portName = NULL;
	else portName = copyString((char *)name);

	[self setBanner:"Controller"];

	if (![self registerPort:portName]) return nil;

	serverLock = syslock_new(1);
	threadCountLock = syslock_new(0);
	threadCount = 1;
	idleThreads = 1;

	serverList = [[LUArray alloc] init];
	[serverList setBanner:"Controller server list"];

	statistics = [[LUDictionary alloc] init];
	[statistics setBanner:"lookupd statistics"];

	[statistics setValue:_PROJECT_BUILD_INFO_ forKey:"# Build"];
	[statistics setValue:_PROJECT_VERSION_    forKey:"# Version"];

	[self newAgent:[CacheAgent class] name:"CacheAgent"];
	[self newAgent:[DNSAgent class] name:"DNSAgent"];
	[self newAgent:[NILAgent class] name:"NILAgent"];

	/* 
	 * Build a list of local network addresses
	 */
	[self initNetAddrList];

	[self initConfig];

	loginUser = nil;

	machRPC = [[MachRPC alloc] init:self];

	dns = [[DNSAgent alloc] init];
	if (dns != nil)
	{
		dnsSearchList = [dns searchList];
		[dns release];
	}

	return self;
}

- (char *)portName
{
	return portName;
}

- (char **)dnsSearchList
{
	return dnsSearchList;
}

- (char **)netAddrList
{
	return netAddrList;
}

- (void)dealloc
{
	if (dnsSearchList != NULL) freeList(dnsSearchList);
	dnsSearchList = NULL;

	[machRPC release];
	machRPC = nil;

	if (serverList != nil)
		[serverList release];

	if (portName != NULL) 
	{
		sys_destroy_service(portName);
		freeString(portName);
	}
	portName = NULL;

	sys_port_free(server_port);

	if (loginUser != nil) [loginUser release];

	syslock_free(serverLock);
	syslock_free(threadCountLock);

	if (statistics != nil) [statistics release];
	freeList(agentNames);
	agentNames = NULL;
	free(agents);

	freeList(netAddrList);
	netAddrList = NULL;

	[super dealloc];
}

- (BOOL)registerPort:(char *)name
{
	kern_return_t status;
	int restart;

	if (portName == NULL) return YES;

	restart = 0;
	system_log(LOG_DEBUG, "Registering service \"%s\"", portName);

	if (streq(name, DefaultName)) restart = 1;

	status = sys_create_service(name, &server_port, restart);
	if (status == KERN_SUCCESS) return YES;

	system_log(LOG_ERR, "Can't create service! (error %d)", status);
	return NO;
}

- (void)startServerThread
{
	Thread *t;

	syslock_lock(serverLock);

	/*
	 * Create the thread
	 */
	t = [[Thread alloc] init];
	[t setName:"IPC Server"];
	[t shouldTerminate:YES];
	[t run:@selector(serverLoop) context:self];
	idleThreads = 1;

	syslock_unlock(serverLock);

	system_log(LOG_DEBUG, "Started IPC Server");
}

/*
 * Get an idle server from the server list
 */
- (LUServer *)checkOutServer
{
	LUServer *server;
	int i;

	syslock_lock(serverLock);
	server = nil;

	for (i = [serverList count] - 1; i >= 0; i--)
	{
		if ([[serverList objectAtIndex:i] isIdle])
		{
			server = [serverList objectAtIndex:i];
			[server setIsIdle:NO];
			break;
		}
	}

	if (server == nil)
	{
		/*
		 * No servers available - create a new server 
		 */
		server = [[LUServer alloc] init];
		[server setIsIdle:NO];
		[serverList addObject:server];
		[server release];
	}

	syslock_unlock(serverLock);
	return server;
}

- (void)checkInServer:(LUServer *)server
{
	int i, len, idleServerCount;

	syslock_lock(serverLock);

	[server setIsIdle:YES];

	idleServerCount = 0;
	len = [serverList count];
	for (i = 0; i < len; i++)
	{
		if ([[serverList objectAtIndex:i] isIdle]) idleServerCount++;
	}

	if (idleServerCount > maxIdleServers)
	{
		[serverList removeObject:server];
	}

	syslock_unlock(serverLock);
}

- (void)setLoginUser:(int)uid
{
	LUServer *s;
	char *scratch, *name;
	int status;

	if (loginUser != nil)
	{
		[cacheAgent removeObject:loginUser];
		[loginUser release];
		loginUser = nil;
	}

	status = asprintf(&scratch, "%d", uid);
	if (status < 0) return;

	s = [self checkOutServer];
	loginUser = [s itemWithKey:"uid" value:scratch category:LUCategoryUser];
	[self checkInServer:s];
	free(scratch);

	if (loginUser != nil)
	{
		[cacheAgent addObject:loginUser key:"name" category:LUCategoryUser];
		[cacheAgent addObject:loginUser key:"uid" category:LUCategoryUser];
		[loginUser setTimeToLive:(time_t)-1];
		name = [loginUser banner];
		if (name != NULL)
		{
			status = asprintf(&scratch, "%s (console user)", [loginUser banner]);
			if (status < 0) return;
			[loginUser setBanner:scratch];
			free(scratch);
		}
	}
}

- (void)flushCache
{
	[cacheAgent flushCache];
}

- (void)suspend
{
	/* XXX suspend */
}

/*
 * This is just here to send a message to the server port.
 * This wakes the thread blocked on message receive in serverLoop.
 */
- (void)lookupdMessage
{
	sys_port_type s;
	kern_return_t status;
	int proc;

	s = lookupd_port(portName);
	status = _lookup_link(s, "_getstatistics", &proc);

	[[Thread currentThread] terminateSelf];
}

- (unsigned int)memorySize
{
	unsigned int size, i;

	size = [super memorySize];

	size += 60;
	if (serverLock != NULL) size += sizeof(syslock);

	size += (NCATEGORIES * 4);

	if (agentNames != NULL)
	{
		for (i = 0; agentNames[i] != NULL; i++)
		{
			size += 4;
			size += (strlen(agentNames[i]) + 1);
		}
	}
	if (dnsSearchList != NULL)
	{
		for (i = 0; dnsSearchList[i] != NULL; i++)
		{
			size += 4;
			size += (strlen(dnsSearchList[i]) + 1);
		}
	}

	if (portName != NULL) size += (strlen(portName) + 1);

	size += (agentCount * 4);

	return size;
}

@end
