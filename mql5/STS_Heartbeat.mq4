//+------------------------------------------------------------------+
//| STS_Heartbeat.mq4  (MT4 version, same output as the MT5 one)     |
//| Swift Trading Services - fleet heartbeat for the sts-fleet MCP   |
//|                                                                  |
//| Writes account health to Common\Files\<InpFolder>\status\<login>.json
//| and recent deals to Common\Files\<InpFolder>\deals\<login>.json. |
//| Places no trades, modifies no orders. Attach to ONE chart per    |
//| terminal (any symbol, any timeframe).                            |
//+------------------------------------------------------------------+
#property strict
#property copyright   "Swift Trading Services"
#property version     "1.00"
#property description "STS fleet heartbeat. Read-only: writes account health JSON, never trades."

#define HB_VERSION "1.0-mt4"
#define HB_SCHEMA  1

input string InpMachine        = "";          // Machine name (blank = set by setup.bat)
input string InpFirm           = "AUTO";      // Broker hint (AUTO = detect). Prop status comes from firm_rules.json
input double InpInitialBalance = 0;           // Challenge starting balance (0 = first balance seen)
input int    InpIntervalSec    = 60;          // Heartbeat interval in seconds
input int    InpDealsDays      = 7;           // Days of deal history to export
input string InpFolder         = "sts_fleet"; // Subfolder under Common\Files

string   g_machine;
string   g_firm;
string   g_gv;               // global variable prefix
long     g_login;
int      g_lastDealCount  = -1;
ulong    g_lastDealTicket = 0;
datetime g_lastDealsWrite = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string Q(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\t", " ");
   return "\"" + s + "\"";
  }

string D(double v, int digits = 2) { return DoubleToString(v, digits); }
string B(bool v)                   { return v ? "true" : "false"; }

string IsoUtc(datetime t)
  {
   string s = TimeToString(t, TIME_DATE | TIME_SECONDS);   // 2026.10.23 20:00:00
   StringReplace(s, ".", "-");
   StringReplace(s, " ", "T");
   return s + "Z";
  }

// Broker server offset from UTC in seconds, rounded to 30 minutes.
long ServerOffset()
  {
   long off = (long)(TimeCurrent() - TimeGMT());
   return (long)MathRound(off / 1800.0) * 1800;
  }

string ServerDate()
  {
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   return StringFormat("%04d-%02d-%02d", d.year, d.mon, d.day);
  }

double ServerDateNum()
  {
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   return (double)(d.year * 10000 + d.mon * 100 + d.day);
  }

double GvGet(string name, double def)
  {
   string n = g_gv + name;
   if(!GlobalVariableCheck(n)) return def;
   return GlobalVariableGet(n);
  }

void GvSet(string name, double v) { GlobalVariableSet(g_gv + name, v); }

// Write via temp file + move so readers never see a half-written file.
bool WriteAtomic(string rel, string content)
  {
   string tmp = rel + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\t', CP_UTF8);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("STS_Heartbeat: cannot open %s (err %d)", tmp, GetLastError());
      return false;
     }
   FileWriteString(h, content);
   FileClose(h);
   if(!FileMove(tmp, FILE_COMMON, rel, FILE_COMMON | FILE_REWRITE))
     {
      PrintFormat("STS_Heartbeat: cannot move %s -> %s (err %d)", tmp, rel, GetLastError());
      FileDelete(tmp, FILE_COMMON);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Day-start and peak tracking (survives EA/terminal restarts)      |
//+------------------------------------------------------------------+
void UpdateDayAndPeak(double balance, double equity)
  {
   double today = ServerDateNum();
   if(GvGet("day", 0) != today)
     {
      GvSet("day", today);
      GvSet("dsb", balance);
      GvSet("dse", equity);
      GvSet("dcap", (double)TimeGMT());
      GlobalVariablesFlush();
     }
   if(equity > GvGet("peak", 0))
     {
      GvSet("peak", equity);
      GlobalVariablesFlush();
     }
  }

double InitialBalance(string &source)
  {
   if(InpInitialBalance > 0)
     {
      source = "input";
      return InpInitialBalance;
     }
   source = "first_seen";
   double v = GvGet("init", 0);
   if(v <= 0)
     {
      v = AccountInfoDouble(ACCOUNT_BALANCE);
      GvSet("init", v);
      GlobalVariablesFlush();
     }
   return v;
  }

//+------------------------------------------------------------------+
//| Status file                                                      |
//+------------------------------------------------------------------+
string PositionsJson(double &floating, int &count)
  {
   floating = 0;
   count    = 0;
   string items = "";
   int n = OrdersTotal();
   for(int i = 0; i < n; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int ot = OrderType();
      if(ot != OP_BUY && ot != OP_SELL) continue;      // skip pending orders
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      floating += pl;
      count++;
      if(count > 50) continue;
      if(items != "") items += ",";
      items += "{\"ticket\":" + IntegerToString(OrderTicket()) +
               ",\"symbol\":" + Q(OrderSymbol()) +
               ",\"type\":" + Q(ot == OP_BUY ? "buy" : "sell") +
               ",\"volume\":" + D(OrderLots(), 2) +
               ",\"open_price\":" + D(OrderOpenPrice(), 5) +
               ",\"sl\":" + D(OrderStopLoss(), 5) +
               ",\"tp\":" + D(OrderTakeProfit(), 5) +
               ",\"pl\":" + D(pl, 2) +
               ",\"magic\":" + IntegerToString(OrderMagicNumber()) + "}";
     }
   return "[" + items + "]";
  }

void WriteStatus(string state)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(state == "running") UpdateDayAndPeak(balance, equity);

   string initSrc;
   double init = InitialBalance(initSrc);
   double floating;
   int    posCount;
   string positions = PositionsJson(floating, posCount);

   string j = "{";
   j += "\"schema\":" + IntegerToString(HB_SCHEMA);
   j += ",\"ea_version\":" + Q(HB_VERSION);
   j += ",\"platform\":\"MT4\"";
   j += ",\"state\":" + Q(state);
   j += ",\"heartbeat_utc\":" + Q(IsoUtc(TimeGMT()));
   j += ",\"machine\":" + Q(g_machine);
   j += ",\"firm\":" + Q(g_firm);
   j += ",\"interval_sec\":" + IntegerToString(InpIntervalSec);
   j += ",\"terminal\":{";
   j += "\"connected\":" + B(TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
   j += ",\"algo_trading_enabled\":" + B(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);
   j += ",\"account_allows_experts\":" + B(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) != 0);
   j += ",\"ping_ms\":" + D(TerminalInfoInteger(TERMINAL_PING_LAST) / 1000.0, 1);
   j += ",\"build\":" + IntegerToString(TerminalInfoInteger(TERMINAL_BUILD));
   j += ",\"data_path\":" + Q(TerminalInfoString(TERMINAL_DATA_PATH));
   j += "}";
   j += ",\"account\":{";
   j += "\"login\":" + IntegerToString(g_login);
   j += ",\"server\":" + Q(AccountInfoString(ACCOUNT_SERVER));
   j += ",\"company\":" + Q(AccountInfoString(ACCOUNT_COMPANY));
   j += ",\"currency\":" + Q(AccountInfoString(ACCOUNT_CURRENCY));
   long tm = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   j += ",\"trade_mode\":" + Q(tm == ACCOUNT_TRADE_MODE_DEMO ? "demo" : (tm == ACCOUNT_TRADE_MODE_CONTEST ? "contest" : "real"));
   j += ",\"leverage\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE));
   j += ",\"balance\":" + D(balance);
   j += ",\"equity\":" + D(equity);
   j += ",\"margin\":" + D(AccountInfoDouble(ACCOUNT_MARGIN));
   j += ",\"margin_free\":" + D(AccountInfoDouble(ACCOUNT_MARGIN_FREE));
   j += "}";
   j += ",\"day\":{";
   j += "\"server_date\":" + Q(ServerDate());
   j += ",\"start_balance\":" + D(GvGet("dsb", balance));
   j += ",\"start_equity\":" + D(GvGet("dse", equity));
   j += ",\"captured_utc\":" + Q(IsoUtc((datetime)GvGet("dcap", (double)TimeGMT())));
   j += "}";
   j += ",\"initial_balance\":" + D(init);
   j += ",\"initial_balance_source\":" + Q(initSrc);
   j += ",\"peak_equity\":" + D(MathMax(GvGet("peak", equity), equity));
   j += ",\"positions\":{\"count\":" + IntegerToString(posCount) +
        ",\"floating_pl\":" + D(floating) + ",\"items\":" + positions + "}";
   j += "}";

   WriteAtomic(InpFolder + "\\status\\" + IntegerToString(g_login) + ".json", j);
  }

//+------------------------------------------------------------------+
//| Deals file: MT4 has orders, not deals. Each closed order becomes |
//| one closing deal so the server's trade summaries work the same.  |
//+------------------------------------------------------------------+
void WriteDeals()
  {
   int n = OrdersHistoryTotal();
   int lastTicket = 0;
   if(n > 0 && OrderSelect(n - 1, SELECT_BY_POS, MODE_HISTORY)) lastTicket = OrderTicket();
   if(n == g_lastDealCount && (ulong)lastTicket == g_lastDealTicket && TimeGMT() - g_lastDealsWrite < 3600)
      return;

   long     off    = ServerOffset();
   datetime cutoff = TimeCurrent() - (datetime)InpDealsDays * 86400;
   string   items  = "";
   int      kept   = 0;
   for(int i = n - 1; i >= 0 && kept < 500; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      int ot = OrderType();
      if(ot != OP_BUY && ot != OP_SELL) continue;      // skip balance ops and cancelled pendings
      if(OrderCloseTime() < cutoff) continue;
      datetime tu = (datetime)((long)OrderCloseTime() - off);
      string item = "{\"ticket\":" + IntegerToString(OrderTicket()) +
                    ",\"position_id\":" + IntegerToString(OrderTicket()) +
                    ",\"time_utc\":" + Q(IsoUtc(tu)) +
                    ",\"symbol\":" + Q(OrderSymbol()) +
                    ",\"type\":" + Q(ot == OP_BUY ? "sell" : "buy") +   // the closing side
                    ",\"entry\":\"out\"" +
                    ",\"volume\":" + D(OrderLots(), 2) +
                    ",\"price\":" + D(OrderClosePrice(), 5) +
                    ",\"profit\":" + D(OrderProfit()) +
                    ",\"commission\":" + D(OrderCommission()) +
                    ",\"swap\":" + D(OrderSwap()) +
                    ",\"magic\":" + IntegerToString(OrderMagicNumber()) +
                    ",\"comment\":" + Q(OrderComment()) + "}";
      items = (items == "") ? item : item + "," + items;   // keep oldest first
      kept++;
     }

   string j = "{\"schema\":" + IntegerToString(HB_SCHEMA) +
              ",\"login\":" + IntegerToString(g_login) +
              ",\"generated_utc\":" + Q(IsoUtc(TimeGMT())) +
              ",\"server_offset_sec\":" + IntegerToString(off) +
              ",\"platform\":\"MT4\"" +
              ",\"deals\":[" + items + "]}";

   if(WriteAtomic(InpFolder + "\\deals\\" + IntegerToString(g_login) + ".json", j))
     {
      g_lastDealCount  = n;
      g_lastDealTicket = (ulong)lastTicket;
      g_lastDealsWrite = TimeGMT();
     }
  }

//+------------------------------------------------------------------+
//| Auto-configuration                                               |
//+------------------------------------------------------------------+
// setup.bat writes the Windows computer name to Common\Files\sts_fleet_machine.txt
string ReadMachineFile()
  {
   int h = FileOpen("sts_fleet_machine.txt", FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) return "";
   string s = FileReadString(h);
   FileClose(h);
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

string DetectFirm()
  {
   string s = AccountInfoString(ACCOUNT_SERVER) + " " + AccountInfoString(ACCOUNT_COMPANY);
   StringToUpper(s);
   if(StringFind(s, "FTMO") >= 0)                                  return "FTMO";
   if(StringFind(s, "FTUK") >= 0 || StringFind(s, "FT UK") >= 0)  return "FTUK";
   if(StringFind(s, "BLUE") >= 0 && StringFind(s, "GUARD") >= 0)  return "BlueGuardian";
   if(StringFind(s, "BLUEGUARDIAN") >= 0)                         return "BlueGuardian";
   if(StringFind(s, "LITEFINANCE") >= 0 || StringFind(s, "LITE FINANCE") >= 0) return "LiteFinance";
   if(StringFind(s, "ATMOS") >= 0)                                return "Atmos";
   return AccountInfoString(ACCOUNT_COMPANY);   // unknown: server will flag it
  }

//+------------------------------------------------------------------+
//| Event handlers                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_login   = AccountInfoInteger(ACCOUNT_LOGIN);
   g_machine = InpMachine;
   if(g_machine == "") g_machine = ReadMachineFile();
   if(g_machine == "")
     {
      g_machine = "UNSET";
      Print("STS_Heartbeat: machine name unknown. Run setup.bat on this machine or set InpMachine.");
     }
   g_firm = InpFirm;
   if(g_firm == "" || g_firm == "AUTO") g_firm = DetectFirm();
   PrintFormat("STS_Heartbeat: account %I64d, machine %s, firm %s", g_login, g_machine, g_firm);
   g_gv = "STSHB_" + IntegerToString(g_login) + "_";

   FolderCreate(InpFolder, FILE_COMMON);
   FolderCreate(InpFolder + "\\status", FILE_COMMON);
   FolderCreate(InpFolder + "\\deals", FILE_COMMON);

   EventSetTimer(MathMax(10, InpIntervalSec));
   WriteStatus("running");
   WriteDeals();
   return INIT_SUCCEEDED;
  }

void OnTimer()
  {
   WriteStatus("running");
   WriteDeals();
  }

void OnTick() { }   // nothing to do on ticks; the timer drives everything

void OnDeinit(const int reason)
  {
   EventKillTimer();
   string why = "stopped";
   switch(reason)
     {
      case REASON_REMOVE:      why = "stopped_removed";        break;
      case REASON_CLOSE:       why = "stopped_terminal_closed"; break;
      case REASON_RECOMPILE:   why = "stopped_recompiled";     break;
      case REASON_CHARTCLOSE:  why = "stopped_chart_closed";   break;
      case REASON_ACCOUNT:     why = "stopped_account_changed"; break;
      case REASON_PARAMETERS:  why = "stopped_reconfigured";   break;
      case REASON_CHARTCHANGE: why = "stopped_chart_changed";  break;
      default:                 why = "stopped";               break;
     }
   WriteStatus(why);
  }
//+------------------------------------------------------------------+
