//+------------------------------------------------------------------+
//|                                                  MACD Sample.mq5 |
//|                   Copyright 2009-2017, MetaQuotes Software Corp. |
//|                                              http://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2009-2017, MetaQuotes Software Corp."
#property link        "http://www.mql5.com"
#property version     "5.50"
#property description "It is important to make sure that the expert works with a normal"
#property description "chart and the user did not make any mistakes setting input"
#property description "variables (Lots, TakeProfit, TrailingStop) in our case,"
#property description "we check TakeProfit on a chart of more than 2*trend_period bars"

#define MACD_MAGIC 1234502
//---
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Trend.mqh>
#include <Indicators\Oscilators.mqh>
#include <Indicators\Indicators.mqh>
//---
input double InpLots          =0.1; // Lots
input int    InpTakeProfit    =50;  // Take Profit (in pips)
input int    InpTrailingStop  =30;  // Trailing Stop Level (in pips)
input int    InpMACDOpenLevel =3;   // MACD open level (in pips)
input int    InpMACDCloseLevel=2;   // MACD close level (in pips)
input int    InpMATrendPeriod =20;  // MA trend period
input int    InpMATrendValidationPeriod =3;  // The period the trend has to be observed to apply signal
input int    InpMATrendValidationThreshold =2;  // Minimum diff in pips to consider trend as changed
input int    InpSqueezesTreshold =5;  // Below will be considered as price squeeze
input int    InpSqueezeLookbackPeriod =5;  // Periods to look back for price squueze
input bool   InpValidatePriceRange =true;  // Check if the price is not in the dead valley between bb1 and bb2
input bool   InpValidateMATrend =false;  // Check if trend is positive or negative before deals
input bool   InpTradeOnSqueezes =true;  // Trade when price range is narrow

enum SIGNAL
  {
   BUY = 1,
   SELL = -1,
  };

//---
int ExtTimeOut=10; // time out in seconds between trade operations
//+------------------------------------------------------------------+
//| MACD Sample expert class                                         |
//+------------------------------------------------------------------+
class CSampleExpert
  {
protected:
   double            m_adjusted_point;             // point value adjusted for 3 or 5 points
   CTrade            m_trade;                      // trading object
   CSymbolInfo       m_symbol;                     // symbol info object
   CPositionInfo     m_position;                   // trade position object
   CAccountInfo      m_account;                    // account info wrapper
   //--- indicators
   CiBands            m_bands_1;                     // Bollinger bands object indicator handle
   CiBands            m_bands_2;                     // Bollinger bands object indicator handle
   CiMACD             m_macd;                       // MACD object indicator handle
   CIndicators        m_indicators;                 // indicator collection to fast recalculations
   //--- indicator buffers
   MqlRates          rates[];                      // Rates buffer
   //---
   double            m_macd_open_level;
   double            m_macd_close_level;
   double            m_ma_trend_threshold;
   double            m_traling_stop;
   double            m_take_profit;
   double            m_squeeze_threshold;

public:
                     CSampleExpert(void);
                    ~CSampleExpert(void);
   bool              Init(void);
   void              Deinit(void);
   bool              Processing(void);

protected:
   bool              InitCheckParameters(const int digits_adjust);
   bool              InitIndicators(CIndicators *indicators);
   bool              LongClosed(void);
   bool              ShortClosed(void);
   bool              LongModified(void);
   bool              ShortModified(void);
   bool              LongOpened(void);
   bool              ShortOpened(void);
   bool              Signal(SIGNAL opportunity, bool is_price_valid);
   bool              IsPriceRangeValid(SIGNAL opportunity);
   bool              ValidatePrice(SIGNAL opportunity);
   bool              MATrendObserved(SIGNAL direction);
   bool              ValidateMATrend(SIGNAL direction);
   bool              IsPriceSqueezing();
   bool              ValidatePriceSqueezing();
  };
//--- global expert
CSampleExpert ExtExpert;
//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CSampleExpert::CSampleExpert(void) : m_adjusted_point(0),
   m_macd_open_level(0),
   m_macd_close_level(0),
   m_traling_stop(0),
   m_take_profit(0)
  {
   ArraySetAsSeries(rates,true);
  }
//+------------------------------------------------------------------+
//| Destructor                                                       |
//+------------------------------------------------------------------+
CSampleExpert::~CSampleExpert(void)
  {
  }
//+------------------------------------------------------------------+
//| Initialization and checking for input parameters                 |
//+------------------------------------------------------------------+
bool CSampleExpert::Init(void)
  {
//--- initialize common information
   m_symbol.Name(Symbol());                  // symbol
   m_trade.SetExpertMagicNumber(MACD_MAGIC); // magic
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(Symbol());
//--- tuning for 3 or 5 digits
   int digits_adjust=1;
   long digits = m_symbol.Digits();
   int point = m_symbol.Point();
   if(m_symbol.Digits()==3 || m_symbol.Digits()==5)
      digits_adjust=10;
   m_adjusted_point=m_symbol.Point()*digits_adjust;
//--- set default deviation for trading in adjusted points
   m_macd_open_level =InpMACDOpenLevel*m_adjusted_point;
   m_macd_close_level=InpMACDCloseLevel*m_adjusted_point;
   m_ma_trend_threshold=InpMATrendValidationThreshold*m_adjusted_point;
   m_squeeze_threshold=InpSqueezesTreshold*m_adjusted_point;
   m_traling_stop    =InpTrailingStop*m_adjusted_point;
   m_take_profit     =InpTakeProfit*m_adjusted_point;
//--- set default deviation for trading in adjusted points
   m_trade.SetDeviationInPoints(3*digits_adjust);
//---
   if(!InitCheckParameters(digits_adjust))
      return(false);
   CIndicators *indicators_ptr=GetPointer(m_indicators);
   if(!InitIndicators(indicators_ptr))
      return(false);
//--- succeed
   return(true);
  }
//+------------------------------------------------------------------+
//| Checking for input parameters                                    |
//+------------------------------------------------------------------+
bool CSampleExpert::InitCheckParameters(const int digits_adjust)
  {
//--- initial data checks
   if(InpTakeProfit*digits_adjust<m_symbol.StopsLevel())
     {
      printf("Take Profit must be greater than %d",m_symbol.StopsLevel());
      return(false);
     }
   if(InpTrailingStop*digits_adjust<m_symbol.StopsLevel())
     {
      printf("Trailing Stop must be greater than %d",m_symbol.StopsLevel());
      return(false);
     }
//--- check for right lots amount
   if(InpLots<m_symbol.LotsMin() || InpLots>m_symbol.LotsMax())
     {
      printf("Lots amount must be in the range from %f to %f",m_symbol.LotsMin(),m_symbol.LotsMax());
      return(false);
     }
   if(MathAbs(InpLots/m_symbol.LotsStep()-MathRound(InpLots/m_symbol.LotsStep()))>1.0E-10)
     {
      printf("Lots amount is not corresponding with lot step %f",m_symbol.LotsStep());
      return(false);
     }
//--- warning
   if(InpTakeProfit<=InpTrailingStop)
      printf("Warning: Trailing Stop must be less than Take Profit");
//--- succeed
   return(true);
  }
//+------------------------------------------------------------------+
//| Initialization of the indicators                                 |
//+------------------------------------------------------------------+
bool CSampleExpert::InitIndicators(CIndicators *indicators)
  {
//--- check pointer
   if(indicators==NULL)
      return(false);
//--- add MACD object to collection
   if(!indicators.Add(GetPointer(m_macd)))
     {
      printf(__FUNCTION__+": error adding MACD object");
      return(false);
     }
   if(!m_macd.Create(NULL,0,12,26,9,PRICE_CLOSE))
     {
      printf(__FUNCTION__+": error initializing object");
      return(false);
     }
//--- add Bollinger Bands object to collection
   if(!indicators.Add(GetPointer(m_bands_1)))
     {
      printf(__FUNCTION__+": error adding MACD object");
      return(false);
     }
   if(!m_bands_1.Create(NULL,0,InpMATrendPeriod,0,1,PRICE_CLOSE))
     {
      printf(__FUNCTION__+": error BB initializing object");
      return(false);
     }
//--- add Bollinger Bands object to collection
   if(!indicators.Add(GetPointer(m_bands_2)))
     {
      printf(__FUNCTION__+": error adding MACD object");
      return(false);
     }
   if(!m_bands_2.Create(NULL,0,InpMATrendPeriod,0,2,PRICE_CLOSE))
     {
      printf(__FUNCTION__+": error BB initializing object");
      return(false);
     }
//--- succeed
   return(true);
  }

//+------------------------------------------------------------------+
//|Check if MA confirms positive or negative trend                   |
//+------------------------------------------------------------------+
bool CSampleExpert::MATrendObserved(SIGNAL direction)
  {
   bool res = true;
   for(int i=0; i<InpMATrendValidationPeriod-1; i++)
     {
      // positive trend?
      if(direction == BUY)
        {
         if(m_bands_1.Base(i) - m_bands_1.Base(i+1) <= m_ma_trend_threshold)
           {
            res=false;
            break;
           }
        }
      // negative trend?
      if(direction == SELL)
        {
         if(m_bands_1.Base(i) - m_bands_1.Base(i+1) >= m_ma_trend_threshold)
           {
            res=false;
            break;
           }
        }
     }
   return(res);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CSampleExpert::ValidateMATrend(SIGNAL direction)
  {
   bool is_valid = true;
   if(InpValidateMATrend)
      is_valid = MATrendObserved(direction);
   return (is_valid);
  }

//+------------------------------------------------------------------+
//|Check prices are squeezing                   |
//+------------------------------------------------------------------+
bool CSampleExpert::IsPriceSqueezing(void)
  {
   bool res = true;
   for(int i=0; i<InpSqueezeLookbackPeriod; i++)
     {
      if(MathAbs(rates[i].open - rates[i].close) > m_squeeze_threshold)
        {
         res = false;
         break;
        }
     }
   return(res);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CSampleExpert::ValidatePriceSqueezing(void)
  {
   bool is_valid = true;
   if(!InpTradeOnSqueezes)
      is_valid = !IsPriceSqueezing();
   return (is_valid);
  }

//+------------------------------------------------------------------+
//|Check if the prices are in the correct rabge for opening a position
//+------------------------------------------------------------------+
bool CSampleExpert::IsPriceRangeValid(SIGNAL opportunity)
  {

   bool res = true;
   if(opportunity == SELL)
     {
      double price=m_symbol.Bid();
      if(price >= m_bands_1.Upper(0))
        {
         printf("Invalid price range for Sell");
         res = false;
        }
     }
   else
      if(opportunity == BUY)
        {
         double price=m_symbol.Ask();
         if(price <= m_bands_1.Lower(0))
           {
            printf("Invalid price range for Buy");
            res = false;
           }
        }

   return(res);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool CSampleExpert::ValidatePrice(SIGNAL opportunity)
  {
   bool is_price_valid = true;
   if(InpValidatePriceRange)
      is_price_valid = IsPriceRangeValid(opportunity);
   return (is_price_valid);
  }

//+------------------------------------------------------------------+
//| Check for signal                                                 |
//+------------------------------------------------------------------+
bool CSampleExpert::Signal(SIGNAL opportunity, bool is_price_valid=true)
  {
   bool res = false;

   if(opportunity == SELL)
     {
      if(rates[2].high >= m_bands_2.Upper(2) && rates[1].high < m_bands_2.Upper(1) && is_price_valid)
        {
         printf("Sell");
         res = true;
        }
     }
   else
      if(opportunity == BUY)
        {
         if(rates[2].low <= m_bands_2.Lower(2) && rates[1].low > m_bands_2.Lower(1) && is_price_valid)
           {
            printf("Buy");
            res = true;
           }
        }

   return(res);
  }

//+------------------------------------------------------------------+
//| Check for long position closing                                  |
//+------------------------------------------------------------------+
bool CSampleExpert::LongClosed(void)
  {
   bool res=false;
//--- Sell
   if(Signal(SELL, ValidatePrice(BUY) && ValidatePrice(SELL)) && ValidateMATrend(BUY))
     {
      //--- close position
      if(m_trade.PositionClose(Symbol()))
         printf("Long position by %s to be closed",Symbol());
      else
         printf("Error closing position by %s : '%s'",Symbol(),m_trade.ResultComment());
      //--- processed and cannot be modified
      res=true;
     }
   return(res);
  }
//+------------------------------------------------------------------+
//| Check for short position closing                                 |
//+------------------------------------------------------------------+
bool CSampleExpert::ShortClosed(void)
  {
   bool res=false;
//--- should it be closed?
   if(Signal(BUY, ValidatePrice(BUY) && ValidatePrice(SELL)) && ValidateMATrend(SELL))
     {
      //--- close position
      if(m_trade.PositionClose(Symbol()))
         printf("Short position by %s to be closed",Symbol());
      else
         printf("Error closing position by %s : '%s'",Symbol(),m_trade.ResultComment());
      //--- processed and cannot be modified
      res=true;
     }
//--- result
   return(res);
  }
//+------------------------------------------------------------------+
//| Check for long position modifying                                |
//+------------------------------------------------------------------+
bool CSampleExpert::LongModified(void)
  {
   bool res=false;
//--- check for trailing stop
   if(InpTrailingStop>0)
     {
      if(m_symbol.Bid()-m_position.PriceOpen()>m_adjusted_point*InpTrailingStop)
        {
         double sl=NormalizeDouble(m_symbol.Bid()-m_traling_stop,m_symbol.Digits());
         double tp=m_position.TakeProfit();
         if(m_position.StopLoss()<sl || m_position.StopLoss()==0.0)
           {
            //--- modify position
            if(m_trade.PositionModify(Symbol(),sl,tp))
               printf("Long position by %s to be modified",Symbol());
            else
              {
               printf("Error modifying position by %s : '%s'",Symbol(),m_trade.ResultComment());
               printf("Modify parameters : SL=%f,TP=%f",sl,tp);
              }
            //--- modified and must exit from expert
            res=true;
           }
        }
     }
//--- result
   return(res);
  }
//+------------------------------------------------------------------+
//| Check for short position modifying                               |
//+------------------------------------------------------------------+
bool CSampleExpert::ShortModified(void)
  {
   bool   res=false;
//--- check for trailing stop
   if(InpTrailingStop>0)
     {
      if((m_position.PriceOpen()-m_symbol.Ask())>(m_adjusted_point*InpTrailingStop))
        {
         double sl=NormalizeDouble(m_symbol.Ask()+m_traling_stop,m_symbol.Digits());
         double tp=m_position.TakeProfit();
         if(m_position.StopLoss()>sl || m_position.StopLoss()==0.0)
           {
            //--- modify position
            if(m_trade.PositionModify(Symbol(),sl,tp))
               printf("Short position by %s to be modified",Symbol());
            else
              {
               printf("Error modifying position by %s : '%s'",Symbol(),m_trade.ResultComment());
               printf("Modify parameters : SL=%f,TP=%f",sl,tp);
              }
            //--- modified and must exit from expert
            res=true;
           }
        }
     }
//--- result
   return(res);
  }
//+------------------------------------------------------------------+
//| Check for long position opening                                  |
//+------------------------------------------------------------------+
bool CSampleExpert::LongOpened(void)
  {
   bool res=false;
//--- check for long position (BUY) possibility
   if(Signal(BUY, ValidatePrice(BUY) && ValidatePrice(SELL)) && ValidateMATrend(BUY) && ValidatePriceSqueezing())
     {
      double price=m_symbol.Ask();
      double tp   =m_symbol.Bid()+m_take_profit;
      double sl   =NormalizeDouble(m_symbol.Bid()-m_traling_stop,m_symbol.Digits());
      //--- check for free money
      if(m_account.FreeMarginCheck(Symbol(),ORDER_TYPE_BUY,InpLots,price)<0.0)
         printf("We have no money. Free Margin = %f",m_account.FreeMargin());
      else
        {
         //--- open position
         if(m_trade.PositionOpen(Symbol(),ORDER_TYPE_BUY,InpLots,price,sl,tp))
            printf("Position by %s to be opened",Symbol());
         else
           {
            printf("Error opening BUY position by %s : '%s'",Symbol(),m_trade.ResultComment());
            printf("Open parameters : price=%f,TP=%f",price,tp);
           }
        }
      //--- in any case we must exit from expert
      res=true;
     }
//--- result
   return(res);
  }
//+------------------------------------------------------------------+
//| Check for short position opening                                 |
//+------------------------------------------------------------------+
bool CSampleExpert::ShortOpened(void)
  {
   bool res=false;
//--- check for short position (SELL) possibility

   if(Signal(SELL, ValidatePrice(BUY) && ValidatePrice(SELL)) && ValidateMATrend(SELL) && ValidatePriceSqueezing())
     {
      double price=m_symbol.Bid();
      double tp   =m_symbol.Ask()-m_take_profit;
      double sl   =NormalizeDouble(m_symbol.Ask()+m_traling_stop,m_symbol.Digits());
      //--- check for free money
      if(m_account.FreeMarginCheck(Symbol(),ORDER_TYPE_SELL,InpLots,price)<0.0)
         printf("We have no money. Free Margin = %f",m_account.FreeMargin());
      else
        {
         //--- open position
         if(m_trade.PositionOpen(Symbol(),ORDER_TYPE_SELL,InpLots,price,sl,tp))
            printf("Position by %s to be opened",Symbol());
         else
           {
            printf("Error opening SELL position by %s : '%s'",Symbol(),m_trade.ResultComment());
            printf("Open parameters : price=%f,TP=%f",price,tp);
           }
        }
      //--- in any case we must exit from expert
      res=true;
     }
//--- result
   return(res);
  }
//+------------------------------------------------------------------+
//| main function returns true if any position processed             |
//+------------------------------------------------------------------+
bool CSampleExpert::Processing(void)
  {
//--- refresh rates
   if(!m_symbol.RefreshRates())
      return(false);

//--- refresh indicators
   m_indicators.Refresh();
   int rates_count = MathMax(InpSqueezeLookbackPeriod, 3);
   CopyRates(NULL, 0, 0, rates_count, rates);
//--- it is important to enter the market correctly,
//--- but it is more important to exit it correctly...
//--- first check if position exists - try to select it
   if(m_position.Select(Symbol()))
     {
      if(m_position.PositionType()==POSITION_TYPE_BUY)
        {
         //--- try to close or modify long position
         if(LongClosed())
            return(true);
         if(LongModified())
            return(true);
        }
      else
        {
         //--- try to close or modify short position
         if(ShortClosed())
            return(true);
         if(ShortModified())
            return(true);
        }
     }
//--- no opened position identified
   else
     {
      //--- check for long position (BUY) possibility
      if(LongOpened())
         return(true);
      //--- check for short position (SELL) possibility
      if(ShortOpened())
         return(true);
     }
//--- exit without position processing
   return(false);
  }
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit(void)
  {
//--- create all necessary objects
   if(!ExtExpert.Init())
      return(INIT_FAILED);
//--- secceed
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert new tick handling function                                |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   static datetime limit_time=0; // last trade processing time + timeout
//--- don't process if timeout
   if(TimeCurrent()>=limit_time)
     {
      //--- check for data
      if(Bars(Symbol(),Period())>2*InpMATrendPeriod)
        {
         //--- change limit time by timeout in seconds if processed
         if(ExtExpert.Processing())
            limit_time=TimeCurrent()+ExtTimeOut;
        }
     }
  }
//+------------------------------------------------------------------+
