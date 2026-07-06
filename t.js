import axios from "axios";

const response = await axios.get(
  "https://api.netgsm.com.tr/balance/list/xml",
  {
    params: {
      usercode: process.env.NETGSM_USER,
      password: process.env.NETGSM_PASS
    }
  }
);

console.log(response);