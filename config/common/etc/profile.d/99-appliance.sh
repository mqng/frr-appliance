umask 027

case ":$PATH:" in
  *:/usr/local/sbin:*) ;;
  *) PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"; export PATH ;;
esac
