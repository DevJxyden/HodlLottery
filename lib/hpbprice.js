
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}


async function startUpdateHPBPriceThread() {
  // Sleep in loop
  while(true) {

	$.get( "https://api.bibox.com/v1/mdata?cmd=market&pair=HPB_USDT", function( data ) {
        hpbPrice = data["result"]["last"]
		document.getElementById("DIV_hpbPrice").innerHTML = 
		"Current Price: $" + hpbPrice + "&nbsp;&nbsp;&nbsp;&nbsp; Percent Change: "  + data["result"]["percent"]  + "&nbsp;&nbsp;&nbsp;&nbsp;Daily Low: $" + data["result"]["low"] + "&nbsp;&nbsp;&nbsp;&nbsp;Daily High: $" + data["result"]["high"];
	    
	});
  await sleep(60000);
	
  }
}
 